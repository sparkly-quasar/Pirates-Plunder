class_name ServerLobbyBox
extends VBoxContainer

## On a server, before setting sail: every crew and who sails it, as the server
## describes it (Net.lobby), and for the player who leads the game a Set Sail
## button, which gives the seats nobody has taken to the computer. Used by the
## setup screen and, rejoining a saved match, by the server list.

## Whether this player has chosen their crew (only then may the leader sail).
var chosen := false:
	set(value):
		chosen = value
		_refresh()

var _seats: RichTextLabel
var _sail: Button
var _asked := false

func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_seats = RichTextLabel.new()
	_seats.bbcode_enabled = true
	_seats.fit_content = true
	_seats.scroll_active = false
	_seats.custom_minimum_size = Vector2(560, 0)
	_seats.add_theme_font_size_override("normal_font_size", 15)
	add_child(_seats)
	_sail = Button.new()
	_sail.custom_minimum_size = Vector2(0, 40)
	_sail.add_theme_font_size_override("font_size", 17)
	_sail.pressed.connect(_on_sail)
	add_child(_sail)
	Net.lobby_changed.connect(_on_lobby_changed)
	_refresh()

## A method, not a lambda, so Godot disconnects it from the autoload when this
## box goes. A change (someone joining as we asked, say) re-offers the button.
func _on_lobby_changed() -> void:
	_asked = false
	_refresh()

func _refresh() -> void:
	if _seats == null:
		return
	var lobby := Net.lobby
	visible = not lobby.is_empty()
	if not visible:
		return
	var leader := int(lobby.get("leader", -1))
	var lines: Array[String] = []
	var choosing := false
	var open := 0
	for seat in lobby.get("seats", []):
		if not seat is Dictionary:
			continue
		var t := clampi(int(seat.get("team", 0)), 0, GameConfig.MAX_TEAMS - 1)
		var state := ""
		match str(seat.get("who", "")):
			"computer":
				state = "the computer"
			"open":
				state = "waiting for a player..."
				open += 1
			_:
				var who := GameConfig.clean_name(str(seat.get("name", "")))
				if who == "":
					who = "a player"
				if bool(seat.get("captain", false)):
					who = "[color=#ffcc33]Captain[/color] " + who
				if t == GameConfig.my_team:
					who += " (you)"
				var ready := bool(seat.get("ready", false))
				choosing = choosing or not ready
				state = who + (", ready" if ready else ", choosing a crew...")
				if t == leader:
					state += "   [color=#ffdd8c]leads the game[/color]"
		lines.append("[color=#%s]%s[/color]   %s" % [Character.ui_colour(t).to_html(false), GameConfig.team_name(t), state])
	_seats.text = "\n".join(lines)
	_sail.visible = Net.i_lead() and not bool(lobby.get("auto", false))
	if _asked:
		return
	_sail.disabled = not chosen or choosing
	if not chosen:
		_sail.text = "Set Sail (once you've chosen your crew)"
	elif choosing:
		_sail.text = "Set Sail (once everyone here has chosen a crew)"
	elif open > 0:
		_sail.text = "Set Sail Now: the computer sails the %d open crew%s" % [open, "" if open == 1 else "s"]
	else:
		_sail.text = "Set Sail"

func _on_sail() -> void:
	_asked = true
	_sail.disabled = true
	_sail.text = "Setting sail..."
	Net.request_sail()
