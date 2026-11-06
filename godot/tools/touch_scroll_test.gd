extends SceneTree
## Lists dragged with a finger (Touch): on the coaching screen, in the phone
## layout, a tap on a coaching button presses it; a drag that starts on it
## scrolls the list and doesn't press it; a tap afterwards still does; a
## flick glides on. Needs a window (not --headless):
##   xvfb-run -a godot --path . --resolution 1280x720 -s res://tools/touch_scroll_test.gd -- --touch
var pressed := 0
var fails := 0
func _check(ok: bool, what: String) -> void:
	print("  [%s] %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
func _initialize() -> void:
	_run.call_deferred()
func _touch(pos: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = root.get_final_transform() * pos
	e.pressed = down
	Input.parse_input_event(e)
	await process_frame
func _drag(from: Vector2, to: Vector2, steps: int) -> void:
	var at := from
	for i in steps:
		var nxt := from.lerp(to, float(i + 1) / steps)
		var e := InputEventScreenDrag.new()
		e.index = 0
		var k: Transform2D = root.get_final_transform()
		e.position = k * nxt
		e.relative = k.basis_xform(nxt - at)
		e.velocity = k.basis_xform(nxt - at) * 60.0
		Input.parse_input_event(e)
		at = nxt
		await process_frame
func _run() -> void:
	var gc: Node = root.get_node("GameConfig")
	var CS: Script = load("res://scripts/character_stats.gd")
	gc.crew_path = "user://scroll_crew.cfg"
	gc.crew = []
	var names := []
	for i in 12:
		var st = CS.make(i % 5, "S%d" % i)
		gc.crew.append(st.to_dict())
		names.append(st.person_name)
	gc.reset()
	gc.mode = gc.Mode.COMPUTER
	gc.last_party = names
	gc.coaching_sessions = 1
	gc.recruit_due = false
	change_scene_to_file("res://scenes/Coaching.tscn")
	for i in 20:
		await process_frame
	var scroll: ScrollContainer = null
	for n in root.find_children("*", "ScrollContainer", true, false):
		if n.get_v_scroll_bar().max_value > n.get_v_scroll_bar().page:
			scroll = n
	_check(scroll != null, "the coaching list scrolls (more than fits)")
	var button: Button = null
	for b in scroll.find_children("*", "Button", true, false):
		var r: Rect2 = b.get_global_rect()
		if b.is_visible_in_tree() and not b.disabled and scroll.get_global_rect().encloses(r) and r.position.y > scroll.get_global_rect().position.y + 200:
			button = b
			break

	button.pressed.connect(func() -> void: pressed += 1)

	var at := button.get_global_rect().get_center()
	await _touch(at, true)
	await _touch(at, false)
	for i in 3: await process_frame
	_check(pressed == 1, "a tap on a coaching button presses it")
	pressed = 0
	await _touch(at, true)
	await _drag(at, at - Vector2(0, 250), 10)
	await _touch(at - Vector2(0, 250), false)
	for i in 3: await process_frame
	_check(scroll.scroll_vertical > 100 and pressed == 0, "a drag that starts on it scrolls the list (to %d) and doesn't press it" % scroll.scroll_vertical)
	for i in 30: await process_frame
	at = button.get_global_rect().get_center()
	if scroll.get_global_rect().has_point(at):
		await _touch(at, true)
		await _touch(at, false)
		for i in 3: await process_frame
		_check(pressed == 1, "a tap after scrolling presses it")
	scroll.scroll_vertical = 0
	pressed = 0
	for i in 3: await process_frame
	at = button.get_global_rect().get_center()
	await _touch(at, true)
	await _drag(at, at - Vector2(0, 60), 3)
	await _touch(at - Vector2(0, 60), false)
	var let_go := scroll.scroll_vertical
	for i in 20: await process_frame
	_check(scroll.scroll_vertical > let_go and pressed == 0, "a flick glides on after letting go (%d to %d)" % [let_go, scroll.scroll_vertical])
	print("TOUCH_SCROLL_TEST: %s" % ("ALL PASS" if fails == 0 else "FAIL"))
	quit(1 if fails else 0)
