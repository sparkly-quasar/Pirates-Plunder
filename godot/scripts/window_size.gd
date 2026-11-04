extends Node

## Autoload. The desktop game's window.
##
## The project's window size (1152x864) is in screen pixels, and a Retina
## Mac has two of those per point, so on its own the game opened at about a
## quarter of the screen. Instead:
##  - The first time, the window takes most of the screen (FIRST_SHARE of it,
##    in the game's own shape), centred.
##  - After that it opens as it was left: the same size and place, maximised,
##    or full screen. Kept in user://settings.cfg [window], beside the volume.
## Not in a browser (the page decides), on a dedicated server, or in
## headless runs (the tests). Started with --fullscreen or --maximized, the
## window is left as asked. Godot doesn't tell the game about --resolution
## (nor any of its own options), so tools that want an exact size pass
## `-- --keep-window` as well.

const SETTINGS_PATH := "user://settings.cfg"
## How much of the screen's usable area the first window takes.
const FIRST_SHARE := 0.85
## The game's shape: the project's design size.
const DESIGN := Vector2i(1152, 864)
## Smaller than this and the screens don't fit; the window can't be dragged smaller.
const MIN_SIZE := Vector2i(800, 600)

var _save_in := -1.0
var _off := false

func _ready() -> void:
	set_process(false)
	var win := get_window()
	if win.mode != Window.MODE_WINDOWED:
		_off = true # started --fullscreen or --maximized: as asked
	if _off or not applies():
		_off = true
		return
	win.min_size = MIN_SIZE
	_restore(win)
	win.size_changed.connect(func() -> void:
		_save_in = 1.0 # save once the resizing settles
		set_process(true))

func applies() -> bool:
	if OS.has_feature("web") or OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless":
		return false
	var args := OS.get_cmdline_user_args()
	if args.has("--server") or args.has("--keep-window") or OS.get_cmdline_args().has("--server"):
		return false
	return true

## The first window on a screen whose usable area (without the menu bar and
## Dock, or the taskbar) is `usable`: as big as FIRST_SHARE of it allows in
## the game's shape, centred, never smaller than MIN_SIZE (if the screen has
## room for that).
static func first_rect(usable: Rect2i) -> Rect2i:
	var scale := minf(usable.size.x * FIRST_SHARE / DESIGN.x, usable.size.y * FIRST_SHARE / DESIGN.y)
	var size := Vector2i(roundi(DESIGN.x * scale), roundi(DESIGN.y * scale))
	size = size.max(MIN_SIZE).min(usable.size)
	return Rect2i(usable.position + (usable.size - size) / 2, size)

func _restore(win: Window) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	var mode := str(cfg.get_value("window", "mode", ""))
	var rect: Variant = cfg.get_value("window", "rect") if cfg.has_section_key("window", "rect") else null
	if rect is Rect2i and _fits_a_screen(rect):
		win.size = rect.size
		win.position = rect.position
	else:
		var first := first_rect(DisplayServer.screen_get_usable_rect(win.current_screen))
		win.size = first.size
		win.position = first.position
	if mode == "fullscreen":
		win.mode = Window.MODE_FULLSCREEN
	elif mode == "maximized":
		win.mode = Window.MODE_MAXIMIZED

## A saved place that's still on a screen (one may have been unplugged), and
## big enough to use.
func _fits_a_screen(rect: Rect2i) -> bool:
	if rect.size.x < MIN_SIZE.x or rect.size.y < MIN_SIZE.y:
		return false
	for s in DisplayServer.get_screen_count():
		var usable := DisplayServer.screen_get_usable_rect(s)
		# Most of it on this screen (the title bar sits a little above).
		if usable.grow(64).encloses(rect):
			return true
	return false

func _process(delta: float) -> void:
	_save_in -= delta
	if _save_in <= 0.0:
		set_process(false)
		save()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if not _off and is_inside_tree():
			save()

func _exit_tree() -> void:
	if not _off:
		save()

## Keeps how the window is now. In full screen or maximised, the size it had
## before stays, for when it's put back to a window.
func save() -> void:
	var win := get_window()
	if win == null:
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	match win.mode:
		Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN:
			cfg.set_value("window", "mode", "fullscreen")
		Window.MODE_MAXIMIZED:
			cfg.set_value("window", "mode", "maximized")
		Window.MODE_MINIMIZED:
			return # nothing to learn from a minimised window
		_:
			cfg.set_value("window", "mode", "windowed")
			cfg.set_value("window", "rect", Rect2i(win.position, win.size))
	cfg.save(SETTINGS_PATH)
