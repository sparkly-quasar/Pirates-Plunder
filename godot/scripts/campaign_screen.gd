class_name CampaignScreen
extends Control

## The campaign's own screen (Single Player -> Campaign): the fifteen islands
## of THE STAR CHART down the left, won ones marked and the rest locked until
## you get there; on the right the chosen island's briefing (story, goal,
## rules, a look at the island) and your landing party, then Set Sail.
## Finished, it says you're a Captain and offers the ending again.

const CLASS_ORDER := [
	CharacterStats.Kind.SCOUT,
	CharacterStats.Kind.DIGGER,
	CharacterStats.Kind.RUNNER,
	CharacterStats.Kind.FIGHTER,
	CharacterStats.Kind.SWORDSMAN,
]

## The island to show when the screen opens (-1: the next one to play), and
## the landing party last chosen, kept while the game runs.
static var show_chapter := -1
static var last_counts: Dictionary = {}

var chapter := 0
var counts: Dictionary = {}
var list_buttons: Array[Button] = []
var heading: Label
var story: Label
var goal: Label
var tip_label: Label
var rules: Label
var preview: IslandPreview
var count_labels := {}
var name_labels := {}
var total_label: Label
var sail: Button
var vega_note: Label
var progress: Label
var _reset_armed := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	var first := show_chapter if show_chapter >= 0 and Campaign.unlocked(show_chapter) else Campaign.next_open()
	show_chapter = -1
	select(first)

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

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	var title := UiTheme.heading(_label("THE STAR CHART", 38))
	top.add_child(title)
	if Campaign.is_captain():
		top.add_child(CaptainFlag.new(Vector2(30, 20)))
	progress = _label("", 16)
	progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	progress.modulate = Color(1, 1, 1, 0.75)
	top.add_child(progress)
	root.add_child(top)

	# The difficulty levels, each with its own progress.
	var levels := HBoxContainer.new()
	levels.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	for lv in Campaign.LEVEL_NAMES.size():
		var b := Button.new()
		b.name = "Level%s" % Campaign.LEVEL_NAMES[lv]
		b.text = Campaign.LEVEL_NAMES[lv] + ("  (won)" if Campaign.level_done(lv) else "")
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = lv == Campaign.level
		b.custom_minimum_size = Vector2(130, 34)
		b.pressed.connect(func() -> void:
			if Campaign.level != lv:
				Campaign.set_level(lv)
				show_chapter = -1
				get_tree().reload_current_scene())
		levels.add_child(b)
	var blurb := _label(Campaign.LEVEL_BLURBS[Campaign.level], 14)
	blurb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	blurb.modulate = Color(1, 1, 1, 0.7)
	levels.add_child(blurb)
	root.add_child(levels)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 22)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(columns)

	# The islands.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(300, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for i in Campaign.count():
		for act in Campaign.ACTS:
			if int(act[0]) == i:
				var a := _label(str(act[1]), 14)
				a.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
				list.add_child(a)
		var b := Button.new()
		b.name = "Island%d" % (i + 1)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 34)
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(func() -> void: select(i))
		list.add_child(b)
		list_buttons.append(b)

	# The briefing.
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	heading = UiTheme.heading(_label("", 28))
	right.add_child(heading)
	story = _label("", 15)
	story.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	story.custom_minimum_size = Vector2(380, 0)
	right.add_child(story)
	goal = _label("", 16)
	goal.add_theme_color_override("font_color", Color(0.65, 0.90, 0.65))
	goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(goal)
	tip_label = _label("", 14)
	tip_label.name = "Tip"
	tip_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(tip_label)

	var mid := HBoxContainer.new()
	mid.add_theme_constant_override("separation", 18)
	right.add_child(mid)
	var island := VBoxContainer.new()
	island.add_theme_constant_override("separation", 6)
	preview = IslandPreview.new()
	island.add_child(preview)
	rules = _label("", 13)
	rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rules.custom_minimum_size = Vector2(IslandPreview.BOX.x, 0)
	rules.modulate = Color(1, 1, 1, 0.8)
	island.add_child(rules)
	mid.add_child(island)

	var party := VBoxContainer.new()
	party.add_theme_constant_override("separation", 6)
	party.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	party.add_child(_label("YOUR LANDING PARTY", 16))
	for kind in CLASS_ORDER:
		party.add_child(_class_row(kind))
	total_label = _label("", 14)
	party.add_child(total_label)
	vega_note = _label("", 13)
	vega_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vega_note.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	party.add_child(vega_note)
	mid.add_child(party)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(120, 46)
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/Menu.tscn"))
	bottom.add_child(back)
	if Campaign.won_count() > 0:
		var restart := Button.new()
		restart.name = "StartOver"
		restart.text = "Start Over"
		restart.custom_minimum_size = Vector2(150, 46)
		restart.tooltip_text = "Sail the campaign again from the first island. Your crew keeps its training, and a Captain stays a Captain."
		restart.pressed.connect(func() -> void:
			if not _reset_armed:
				_reset_armed = true
				restart.text = "Click again"
				return
			Campaign.reset()
			get_tree().reload_current_scene())
		bottom.add_child(restart)
	if Campaign.is_captain():
		var ending := Button.new()
		ending.name = "WatchEnding"
		ending.text = "Watch the Ending"
		ending.custom_minimum_size = Vector2(180, 46)
		ending.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/Ending.tscn"))
		bottom.add_child(ending)
	sail = UiTheme.primary(Button.new())
	sail.name = "SetSail"
	sail.custom_minimum_size = Vector2(0, 46)
	sail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sail.add_theme_font_size_override("font_size", 20)
	sail.pressed.connect(_set_sail)
	bottom.add_child(sail)
	root.add_child(bottom)

## Shows island `i`'s briefing (only one you've reached).
func select(i: int) -> void:
	if not Campaign.unlocked(i):
		return
	chapter = i
	var c := Campaign.chapter(i)
	heading.text = Campaign.heading(i)
	story.text = str(c.story)
	goal.text = "Goal: " + Campaign.goal_text(i)
	rules.text = "\n".join(Campaign.rules(i))
	tip_label.text = ("Tip: " + Campaign.tip(i)) if Campaign.tip(i) != "" else ""
	preview.show_island(TerrainGrid.new(int(c.seed), int(c.length) as TerrainGrid.Length, int(c.rivals) + 1, float(c.get("stretch", 1.0))))
	GameConfig.crew_first = Campaign.party() # those sailing the campaign land first
	counts = GameConfig.campaign_counts(Campaign.party_size(i), last_counts)
	vega_note.text = ("Vega (Navigator) sails with you too." if Campaign.vega_sails(i)
		else "Vega is held prisoner on this island." if i == Campaign.RESCUE else "")
	_refresh()

func _refresh() -> void:
	var size := Campaign.party_size(chapter)
	var total := 0
	var roster := GameConfig.preview_roster(counts, 0, GameConfig.Mode.COMPUTER)
	for kind in CLASS_ORDER:
		count_labels[kind].text = str(int(counts.get(kind, 0)))
		total += int(counts.get(kind, 0))
		name_labels[kind].text = GameConfig.names_of(roster, kind)
		name_labels[kind].visible = name_labels[kind].text != ""
	total_label.text = "Chosen %d of %d" % [total, size]
	total_label.modulate = Color(1, 1, 1, 0.8) if total == size else Color(1.0, 0.6, 0.45)
	sail.disabled = total != size
	sail.text = ("Sail Again" if Campaign.won(chapter) else "Set Sail") + " to " + str(Campaign.chapter(chapter).title)
	for i in list_buttons.size():
		var b := list_buttons[i]
		var open := Campaign.unlocked(i)
		b.disabled = not open
		b.text = "%d.  %s%s" % [i + 1, Campaign.chapter(i).title if open else "? ? ?", "   (won)" if Campaign.won(i) else ""]
		b.modulate = Color(1.0, 0.92, 0.6) if i == chapter else Color.WHITE
	progress.text = ("Captain! Every island won." if Campaign.is_captain() and Campaign.won_count() == Campaign.count()
		else "%d of %d islands won" % [Campaign.won_count(), Campaign.count()] + ("   ·   Captain" if Campaign.is_captain() else ""))

func _adjust(kind: int, delta: int) -> void:
	var size := Campaign.party_size(chapter)
	var total := 0
	for k in counts:
		total += int(counts[k])
	if delta > 0 and total >= size:
		return
	counts[kind] = clampi(int(counts.get(kind, 0)) + delta, 0, size)
	_refresh()

func _set_sail() -> void:
	last_counts = counts.duplicate()
	Net.leave()
	GameConfig.start_campaign(chapter, counts)
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

## A class: its picture and name, the count with - and +, and underneath who
## from your crew would land as it (veterans first, then new recruits).
func _class_row(kind: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(ClassPicture.new(kind))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 0)
	col.add_child(_label(CharacterStats.make(kind).class_name_, 15))
	var who := _label("", 12)
	who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	who.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	name_labels[kind] = who
	col.add_child(who)
	row.add_child(col)
	row.add_child(_step("-", func() -> void: _adjust(kind, -1)))
	var count := _label("", 17)
	count.custom_minimum_size = Vector2(24, 0)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_labels[kind] = count
	row.add_child(count)
	row.add_child(_step("+", func() -> void: _adjust(kind, 1)))
	return row

func _step(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(36, 30)
	b.pressed.connect(action)
	return b

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l
