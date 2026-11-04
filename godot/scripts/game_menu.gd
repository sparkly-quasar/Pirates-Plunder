class_name GameMenu
extends Control

## The in-game menu: Esc, or the Menu button in the corner. On this computer it
## freezes the game while it's open; online it can pause the game for both
## players instead. Volume, save (games on one computer: Save Game opens the
## three slots, then keep playing or quit; hosting: save and quit), leave,
## and a reminder of the controls.

var main: Node2D
var server: GameServer
var title: Label
var pause_button: Button
var save_button: Button
var leave_button: Button
var note: Label
var volume_label: Label
var _leave_armed := false
var main_box: VBoxContainer
var slots_box: VBoxContainer
var slot_buttons: Array[Button] = []
var slots_note: Label
var after_save: HBoxContainer
var _overwrite_armed := -1

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS # works while the game is frozen
	visible = false

func setup(_main: Node2D, _server: GameServer) -> void:
	main = _main
	server = _server
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP # no clicking the map behind it
	add_child(dim)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.05, 0.96)
	style.border_color = Color(0.85, 0.70, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var both := VBoxContainer.new()
	panel.add_child(both)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	both.add_child(box)
	main_box = box
	slots_box = _build_slots()
	slots_box.visible = false
	both.add_child(slots_box)
	title = _label("", 28)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	box.add_child(_button("Resume  (Esc)", close))
	if Net.is_online():
		pause_button = _button("", func() -> void:
			server.intent(server.viewer_team(), "pause", [not server.paused])
			_refresh.call_deferred())
		box.add_child(pause_button)

	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 10)
	vol_row.add_child(_label("Volume", 16))
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 5
	slider.value = roundf(AudioManager.volume * 100.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 28)
	slider.value_changed.connect(func(v: float) -> void:
		AudioManager.set_volume(v / 100.0)
		volume_label.text = "%d%%" % roundi(v))
	slider.drag_ended.connect(func(_changed: bool) -> void: AudioManager.play(AudioManifest.DIG)) # a sample at the new level
	vol_row.add_child(slider)
	volume_label = _label("%d%%" % roundi(slider.value), 16)
	volume_label.custom_minimum_size = Vector2(48, 0)
	vol_row.add_child(volume_label)
	box.add_child(vol_row)

	if GameConfig.mode == GameConfig.Mode.HOST:
		save_button = _button("Save and Quit to Menu", _save_and_quit)
		box.add_child(save_button)
	elif GameConfig.can_save():
		save_button = _button("Save Game...", _show_slots)
		box.add_child(save_button)
	leave_button = _button("", _leave)
	box.add_child(leave_button)

	note = _label("", 14)
	note.add_theme_color_override("font_color", Color(1.0, 0.75, 0.45))
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)

	var ver := _label("Pirates Plunder  ·  version " + GameConfig.version(), 12)
	ver.modulate = Color(1, 1, 1, 0.45)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var keys := _label(("Tap one of yours, then where to go  ·  tap an enemy to attack\nDouble-tap one of yours to dig  ·  drag to look around  ·  pinch to zoom\nHand a chest over: pick who takes it, then double-tap the carrier\n(they go over and ask for it; carrier picked, a team-mate beside them takes it)") if Touch.enabled else "Click one of yours, then where to go  ·  click an enemy to attack\n1 stand  ·  2 run  ·  3 crawl  ·  SPACE or double-click to dig\nENTER end turn  ·  TAB next person  ·  C centre on them  ·  wheel zoom\nHand a chest over: pick who takes it, then double-click the carrier\n(they go over and ask for it; carrier picked, a team-mate beside them takes it)", 12)
	keys.modulate = Color(1, 1, 1, 0.6)
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(keys)
	box.add_child(ver)

func open() -> void:
	visible = true
	_leave_armed = false
	note.text = ""
	_show_main()
	if not Net.is_online():
		get_tree().paused = true
	_refresh()

func close() -> void:
	visible = false
	get_tree().paused = false

func _refresh() -> void:
	var online := Net.is_online()
	title.text = "MENU" if online else "PAUSED"
	if pause_button:
		pause_button.text = "Resume the Game for Both" if server.paused else "Pause the Game for Both"
	if online and server.paused:
		title.text = "PAUSED"
	leave_button.text = ("Leave the Match" if online else "Quit to Menu Without Saving") if not _leave_armed \
		else "Click again to leave"

func _process(_delta: float) -> void:
	if visible and pause_button:
		_refresh() # the other player may pause or resume

func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if slots_box.visible:
			_show_main() # Esc backs out of the slots first
		else:
			close()
		get_viewport().set_input_as_handled()

# --- the save slots ---------------------------------------------------------

func _build_slots() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	var head := _label("SAVE GAME", 28)
	head.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(head)
	var hint := _label("Pick a slot. Your crew's training is kept on its own, whether you save or not.", 13)
	hint.modulate = Color(1, 1, 1, 0.65)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	for i in GameConfig.SLOTS:
		var b := _button("", func() -> void: _save_in(i))
		b.name = "Slot%d" % (i + 1)
		b.custom_minimum_size = Vector2(0, 58)
		b.add_theme_font_size_override("font_size", 15)
		box.add_child(b)
		slot_buttons.append(b)
	slots_note = _label("", 14)
	slots_note.add_theme_color_override("font_color", Color(1.0, 0.75, 0.45))
	slots_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slots_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(slots_note)
	after_save = HBoxContainer.new()
	after_save.add_theme_constant_override("separation", 10)
	var keep := _button("Keep Playing", close)
	keep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	after_save.add_child(keep)
	var quit := _button("Quit to Menu", _quit_to_menu)
	quit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	after_save.add_child(quit)
	after_save.visible = false
	box.add_child(after_save)
	box.add_child(_button("Back", _show_main))
	return box

func _show_main() -> void:
	if slots_box == null:
		return
	slots_box.visible = false
	main_box.visible = true

func _show_slots() -> void:
	var why := server.save_blocker()
	if why != "":
		note.text = "Can't save yet: " + why
		return
	main_box.visible = false
	slots_box.visible = true
	after_save.visible = false
	slots_note.text = ""
	_overwrite_armed = -1
	_refresh_slots()
	if not Touch.enabled:
		var mine := GameConfig.slot_paths().find(GameConfig.current_slot)
		slot_buttons[maxi(mine, 0)].grab_focus.call_deferred()

## Each slot says what's in it; the one this game came from (or was last
## saved to) is marked.
func _refresh_slots() -> void:
	for i in slot_buttons.size():
		var path := GameConfig.slot_path(i)
		var info := GameConfig.save_info(path)
		var text := "Slot %d:  " % (i + 1)
		if info.is_empty():
			text += "empty"
		else:
			text += str(info.summary)
			var when := GameConfig.saved_when(int(info.saved_at))
			if when != "":
				text += "\n" + when
		if path == GameConfig.current_slot:
			text += "   (this game)"
		if _overwrite_armed == i:
			text = "Slot %d: click again to save over it" % (i + 1)
		slot_buttons[i].text = text

## The kind of game, for a slot's summary: "Single player (Normal)".
func _kind() -> String:
	if GameConfig.in_campaign():
		return "Campaign (%s), %s" % [Campaign.LEVEL_NAMES[Campaign.level], Campaign.heading(GameConfig.campaign_chapter)]
	return {
		GameConfig.Mode.COMPUTER: "Single player (%s)" % GameConfig.DIFFICULTY_NAMES[GameConfig.difficulty],
		GameConfig.Mode.HOTSEAT: "%d crews, one computer" % GameConfig.team_count,
		GameConfig.Mode.SOLO: "Practice",
		GameConfig.Mode.HOST: "Online, %d crews" % GameConfig.team_count,
	}.get(GameConfig.mode, "Game")

## Saves into slot `i`. A slot holding a different game asks for a second
## click first; the slot this game came from saves straight over.
func _save_in(i: int) -> void:
	var why := server.save_blocker()
	if why != "":
		slots_note.text = "Can't save yet: " + why
		return
	var path := GameConfig.slot_path(i)
	if GameConfig.save_info(path).size() > 0 and path != GameConfig.current_slot and _overwrite_armed != i:
		_overwrite_armed = i
		slots_note.text = "Slot %d holds another game. Click it again to save over it." % (i + 1)
		_refresh_slots()
		return
	_overwrite_armed = -1
	GameConfig.save_game(server.save_state(), "%s · turn %d · island #%d" % [_kind(), server.turn, GameConfig.island_seed], path)
	GameConfig.current_slot = path
	slots_note.text = "Saved in slot %d." % (i + 1)
	after_save.visible = true
	_refresh_slots()

func _save_and_quit() -> void:
	var why := server.save_blocker()
	if why != "":
		note.text = "Can't save yet: " + why
		return
	GameConfig.save_game(server.save_state(), "%s · turn %d · island #%d" % [_kind(), server.turn, GameConfig.island_seed])
	if GameConfig.mode == GameConfig.Mode.HOST:
		GameConfig.menu_notice = "Game saved. Choose Continue Online Match, and your friends join again to pick it up."
		save_button.disabled = true
		for id in Net.guests:
			Net.updater.say_goodbye(int(id), "Your friend saved the game to finish later. Join them again when they continue it.")
		await get_tree().create_timer(0.6).timeout # so the goodbye arrives
	else:
		GameConfig.menu_notice = "Game saved. Choose Continue to pick it up again."
	_quit_to_menu()

func _leave() -> void:
	if not _leave_armed:
		_leave_armed = true
		note.text = ("The game will end for everyone." if GameConfig.mode == GameConfig.Mode.HOST
			else "The computer will sail your crew.") if Net.is_online() else "This game won't be saved."
		_refresh()
		return
	_quit_to_menu()

func _quit_to_menu() -> void:
	get_tree().paused = false
	Net.leave()
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.add_theme_font_size_override("font_size", 17)
	b.pressed.connect(action)
	return b

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l
