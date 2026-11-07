extends Control

## The waiting room either side of a networked game.
##
## HOST: shows the addresses friends can type, and who has taken which crew.
## When every friend's seat is filled and they've all picked their crews, the
## expedition starts for everyone. The host can also start early and give any
## empty seats to the computer.
## GUEST: type the host's address and join; once connected, it's on to the
## setup screen to pick a PIRATE crew for the host's island.

const SAVE_PATH := "user://net.cfg"
const DOWNLOAD_URL := "https://tailscale.com/download"
const ADMIN_URL := "https://login.tailscale.com/admin/machines"
const SHARING_URL := "https://tailscale.com/kb/1084/sharing"

var status_label: Label
var address_edit: LineEdit
var join_button: Button
var seats_label: RichTextLabel
var start_now: Button
# A friend with a different version: the offer to get theirs, and progress.
var update_box: VBoxContainer
var update_label: Label
var update_button: Button
var update_bar: ProgressBar
var _update_peer := 0
var _update_version := ""

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
	centre.custom_minimum_size = Vector2(660, 0)
	centre.add_theme_constant_override("separation", 12)
	add_child(centre)

	Net.opponent_left.connect(_on_opponent_left)
	Net.seats_changed.connect(_refresh_seats)
	if GameConfig.mode == GameConfig.Mode.HOST:
		_build_host(centre)
	else:
		_build_guest(centre)

	var back := Button.new()
	back.text = "Back to Menu"
	back.custom_minimum_size = Vector2(0, 36)
	back.pressed.connect(func() -> void:
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn"))
	centre.add_child(_gap(10))
	centre.add_child(back)

# --- host ------------------------------------------------------------------

func _build_host(centre: VBoxContainer) -> void:
	centre.add_child(_title(("CONTINUING: " + GameConfig.match_summary().to_upper()) if Net.resuming
		else "HOSTING ISLAND #%d" % GameConfig.island_seed))
	var addresses := Net.local_addresses()
	var lines: Array[String] = []
	for a in addresses:
		lines.append(("%s   (Tailscale)" % a) if Net.is_tailscale(a) else ("%s   (same Wi-Fi only)" % a))
	if lines.is_empty():
		lines.append("No network found — are you online?")
	elif not addresses.any(Net.is_tailscale):
		lines.append("(No Tailscale address yet: to play over the internet, switch Tailscale on.)")
	var intro := _label("Friends join by typing one of these addresses:", 16)
	centre.add_child(intro)
	var addr := _label("\n".join(lines), 22)
	addr.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	centre.add_child(addr)
	centre.add_child(_steps("Same Wi-Fi? Your friend can type the Wi-Fi address and that's all.\n\nOver the internet, Tailscale connects you, but only once you've shared this computer with your friend:",
		["Install Tailscale on both computers (Download Tailscale, below), and each sign in with your own account.",
		"Here: open the Tailscale admin console (button below), go to Machines, click the ... beside this computer, choose Share, and send your friend the invite link.",
		"Your friend opens the link and accepts. This computer then appears in their Tailscale menu.",
		"Your friend types the Tailscale address above (the one starting 100.) into Join a Game.",
		"If this computer asks whether to allow incoming connections, say yes."]))
	centre.add_child(_link_row([["Download Tailscale", DOWNLOAD_URL], ["Open the Tailscale Admin Console", ADMIN_URL], ["How Sharing Works", SHARING_URL]]))
	centre.add_child(_gap(8))
	seats_label = RichTextLabel.new()
	seats_label.bbcode_enabled = true
	seats_label.fit_content = true
	seats_label.scroll_active = false
	seats_label.add_theme_font_size_override("normal_font_size", 16)
	seats_label.custom_minimum_size = Vector2(640, 0)
	centre.add_child(seats_label)
	status_label = _label("Waiting for friends to rejoin. Each gets their own crew back..." if Net.resuming
		else "Waiting for friends to join...", 18)
	centre.add_child(status_label)
	start_now = Button.new()
	start_now.custom_minimum_size = Vector2(0, 38)
	start_now.pressed.connect(_on_start_now)
	centre.add_child(start_now)
	var chat := ChatBox.new()
	chat.lines = 4
	centre.add_child(chat)
	_build_update_box(centre)
	Net.guest_connected.connect(_on_guest_connected)
	Net.guest_ready.connect(_on_guest_ready)
	_refresh_seats()

# --- guest -----------------------------------------------------------------

func _build_guest(centre: VBoxContainer) -> void:
	centre.add_child(_title("JOIN A GAME"))
	centre.add_child(_steps("Same Wi-Fi? Just type the address your friend's Host screen shows.\n\nOver the internet, you'll use Tailscale:",
		["Install Tailscale (Download Tailscale, below) and sign in with your own account.",
		"Ask your friend to share their computer with you in Tailscale (their Host screen explains how), then open the invite link they send and accept it.",
		"Make sure Tailscale is switched on, then type your friend's Tailscale address (it starts with 100.) below."]))
	centre.add_child(_link_row([["Download Tailscale", DOWNLOAD_URL], ["How Tailscale Sharing Works", SHARING_URL]]))
	centre.add_child(_gap(4))
	centre.add_child(_label("Your friend's address (from their Host screen), or a server's:", 16))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "e.g. 100.101.102.103  or  play.example.com"
	address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address_edit.custom_minimum_size = Vector2(0, 40)
	address_edit.add_theme_font_size_override("font_size", 20)
	address_edit.text = _saved_address()
	address_edit.text_submitted.connect(func(_t: String) -> void: _join())
	row.add_child(address_edit)
	join_button = Button.new()
	join_button.text = "Join"
	join_button.custom_minimum_size = Vector2(110, 40)
	join_button.pressed.connect(_join)
	row.add_child(join_button)
	centre.add_child(row)
	status_label = _label("", 16)
	centre.add_child(status_label)
	_build_update_box(centre)
	Net.joined.connect(_on_joined)
	Net.join_failed.connect(_on_join_failed)
	address_edit.grab_focus.call_deferred()
	if GameConfig.auto_join != "":
		# Back from updating: rejoin the same friend.
		address_edit.text = GameConfig.auto_join
		GameConfig.auto_join = ""
		_join.call_deferred()

# Methods rather than lambdas, so Godot disconnects them from the Net autoload
# when this screen goes away.
func _on_guest_connected() -> void:
	status_label.text = "A friend is here — they're choosing their crew..."

func _on_guest_ready(_counts: Dictionary) -> void:
	if Net.all_seats_ready():
		status_label.text = "Setting sail..."
		Net.start_match()
	else:
		status_label.text = "Waiting for the others..."

## Host: every crew and who's sailing it, as friends come and go.
func _refresh_seats() -> void:
	if seats_label == null:
		return
	var lines: Array[String] = []
	for t in GameConfig.team_count:
		var state := "you"
		if t > 0:
			if GameConfig.is_computer(t):
				state = "the computer"
			elif Net.peer_for(t) == 0:
				state = "waiting for a friend..."
			elif Net.has_chosen(t):
				state = "a friend, ready"
			else:
				state = "a friend, choosing their crew..."
		lines.append("[color=#%s]%s[/color]   %s" % [Character.ui_colour(t).to_html(false), GameConfig.team_name(t), state])
	seats_label.text = "\n".join(lines)
	var empty := Net.open_seats().size()
	var choosing := false
	for t in range(1, GameConfig.team_count):
		if Net.peer_for(t) != 0 and not Net.has_chosen(t):
			choosing = true
	var held := Net.owners_missing()
	start_now.disabled = choosing or not held.is_empty()
	if not held.is_empty():
		# A saved game: it waits for the friends who sailed it.
		start_now.text = "Waiting for the %s' player%s to come back" % [", ".join(held.map(func(t: int) -> String: return GameConfig.team_name(t))), "" if held.size() == 1 else "s"]
	elif choosing:
		start_now.text = "Start Now (once everyone here has chosen a crew)"
	elif empty > 0:
		start_now.text = "Start Now: the computer sails the %d empty crew%s" % [empty, "" if empty == 1 else "s"]
	else:
		start_now.text = "Set Sail"

func _on_start_now() -> void:
	Net.fill_open_seats()
	if Net.all_seats_ready():
		status_label.text = "Setting sail..."
		Net.start_match()

func _on_joined() -> void:
	_save_address(address_edit.text)
	if Net.resuming:
		# A saved match: our crew is already chosen. Wait here to set sail.
		join_button.disabled = true
		status_label.text = "Rejoined the saved match as the %s. Waiting for everyone else..." % GameConfig.team_name(GameConfig.my_team).to_upper()
		return
	get_tree().change_scene_to_file("res://scenes/Setup.tscn")

func _on_join_failed(reason: String) -> void:
	status_label.text = reason
	if reason.begins_with("Couldn't reach"):
		status_label.text += "\nCheck that Tailscale is on for both of you, that your friend has shared\ntheir computer with you and you've accepted, and that they're on the Host screen."
	join_button.disabled = false

func _join() -> void:
	var err := Net.join_game(address_edit.text)
	if err != OK:
		status_label.text = "That doesn't look like an address."
		return
	join_button.disabled = true
	status_label.text = "Connecting to %s..." % address_edit.text.strip_edges()

func _on_opponent_left() -> void:
	if GameConfig.mode == GameConfig.Mode.HOST:
		status_label.text = "A friend left. Waiting for someone to join..."
	else:
		status_label.text = Net.farewell("The host closed the game.")
		join_button.disabled = false

func _saved_address() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return ""
	return str(cfg.get_value("net", "last_address", ""))

func _save_address(address: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "last_address", address.strip_edges())
	cfg.save(SAVE_PATH)

# --- a friend with another version -----------------------------------------

func _build_update_box(centre: VBoxContainer) -> void:
	update_box = VBoxContainer.new()
	update_box.add_theme_constant_override("separation", 6)
	update_box.visible = false
	update_label = _label("", 16)
	update_label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	update_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	update_label.custom_minimum_size = Vector2(640, 0)
	update_box.add_child(update_label)
	update_button = Button.new()
	update_button.custom_minimum_size = Vector2(0, 40)
	update_button.add_theme_font_size_override("font_size", 18)
	update_button.pressed.connect(_on_get_update)
	update_box.add_child(update_button)
	update_bar = ProgressBar.new()
	update_bar.custom_minimum_size = Vector2(0, 22)
	update_bar.visible = false
	update_box.add_child(update_bar)
	centre.add_child(update_box)
	Net.updater.versions_differ.connect(_on_versions_differ)
	Net.updater.download_progress.connect(_on_download_progress)
	Net.updater.download_failed.connect(_on_download_failed)
	Net.updater.installing.connect(_on_installing)
	Net.updater.serving_progress.connect(_on_serving_progress)

func _on_versions_differ(peer: int, version: String, newer: bool, can_get: bool) -> void:
	var mine := GameConfig.version()
	update_box.visible = true
	update_bar.visible = false
	update_button.visible = false
	var hosting := GameConfig.mode == GameConfig.Mode.HOST
	var server := Net.updater.is_dedicated(peer)
	var friend := "A friend joined with" if hosting else ("The server has" if server else "Your friend has")
	if not newer and server:
		update_label.text = "The server has an older version (%s; you have %s). Whoever runs it needs to update it before you can play there." % [version, mine]
		return
	if not newer:
		update_label.text = "%s an older version (%s; you have %s). Their game is offering to get yours from you." % [friend, version, mine]
		return
	if not can_get:
		update_label.text = "%s version %s and you have %s, but their copy can't send one for this computer. Download %s from the release page." % [friend, version, mine, version]
		return
	_update_peer = peer
	_update_version = version
	update_label.text = "%s version %s and you have %s. You both need the same one: get it from them, and the game will update itself and restart%s." % [
		friend, version, mine, " (hosting stops while it does)" if hosting else " and rejoin"]
	update_button.text = "Get Version %s From %s" % [version, "the Server" if server else "Your Friend"]
	update_button.visible = true
	update_button.disabled = false
	if join_button:
		join_button.disabled = true
	status_label.text = ""
	if server:
		# Nothing to decide: a server only lets its own version play.
		update_label.text = "The server has version %s and you have %s. Updating: the game will restart and rejoin by itself." % [version, mine]
		_on_get_update.call_deferred()
	elif OS.get_cmdline_user_args().has("--accept-update"):
		_on_get_update.call_deferred() # the end-to-end test, which can't click

func _on_get_update() -> void:
	update_button.disabled = true
	update_bar.visible = true
	update_bar.value = 0
	update_label.text = "Asking %s for version %s..." % ["the server" if Net.updater.is_dedicated(_update_peer) else "your friend", _update_version]
	Net.updater.download_from(_update_peer)

func _on_download_progress(done: int, total: int) -> void:
	update_bar.visible = true
	update_bar.value = 100.0 * done / maxf(total, 1.0)
	update_label.text = "Downloading version %s from %s: %d of %d MB" % [
		_update_version, "the server" if Net.updater.is_dedicated(_update_peer) else "your friend",
		int(done / 1e6), int(total / 1e6)]

func _on_download_failed(reason: String) -> void:
	update_label.text = reason
	update_bar.visible = false
	update_button.disabled = false

func _on_installing(message: String) -> void:
	update_label.text = message
	update_button.visible = false
	update_bar.visible = false

func _on_serving_progress(_peer: int, done: int, total: int) -> void:
	update_box.visible = true
	update_button.visible = false
	update_bar.visible = true
	update_bar.value = 100.0 * done / maxf(total, 1.0)
	update_label.text = "Sending your version of the game to a friend: %d of %d MB" % [int(done / 1e6), int(total / 1e6)]

# --- small ui helpers ------------------------------------------------------

## An intro line and numbered steps, in the small print style.
func _steps(intro: String, steps: Array) -> Label:
	var lines: Array[String] = [intro]
	for i in steps.size():
		lines.append("  %d.  %s" % [i + 1, steps[i]])
	var l := _label("\n".join(lines), 13)
	l.modulate = Color(1, 1, 1, 0.72)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(640, 0)
	return l

## Buttons that open a web page in the player's browser.
func _link_row(links: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for link in links:
		var b := Button.new()
		b.text = link[0]
		b.pressed.connect(func() -> void: OS.shell_open(link[1]))
		row.add_child(b)
	return row

func _title(text: String) -> Label:
	var l := _label(text, 30)
	l.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
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
