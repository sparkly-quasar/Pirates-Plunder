extends Node

## Autoload. The one place that talks to the network.
##
## Up to four players: the HOST plays the NAVS and runs the real GameServer —
## every rule is decided on the host's machine. Each GUEST sails one of the
## other crews (the PIRATES, CORSAIRS or BUCCANEERS); their clicks travel to the
## host as intents, and the host sends each of them snapshots of the game as
## their own crew sees it. Godot's ENet does the transport, and a copy running
## in a web browser uses WebSockets instead (a dedicated server takes both at
## once: scripts/dual_peer.gd).
##
## Reaching each other is left to the network: on the same Wi-Fi the host's
## local address works, and anywhere else everyone runs Tailscale and the
## guests type the host's Tailscale address (100.x.y.z).
##
## A DEDICATED SERVER (scripts/dedicated_server.gd) is a host with no crew of
## its own: it runs the same rules, and every crew, the NAVS included, is a
## player online or the computer. Anyone who can reach its address can play,
## no Tailscale needed. `dedicated` is set on the server, and on a guest once
## the server's welcome says so.
##
## Game traffic goes through this autoload rather than straight to the game
## scene, because the autoload exists on every machine from launch — so no
## message can arrive for a scene the other side hasn't finished loading.

signal guest_connected                 ## host: a friend arrived (and was given a crew)
signal guest_ready(counts: Dictionary) ## host: a friend picked their crew
signal seats_changed                   ## host: someone arrived, chose, or left
signal guest_left(team: int)           ## host: a friend left; the computer sails their crew now
signal joined                          ## guest: connected and got the island
signal join_failed(reason: String)     ## guest: couldn't connect / refused
signal opponent_left                   ## guest: the host disconnected
signal match_changed                   ## either: crews, coaching or readiness changed between games
signal peer_refused(id: int, reason: String) ## host: someone was turned away (for the server's log)
signal lobby_changed                   ## guest on a server: who's in which seat, and who leads, changed
signal sail_requested(id: int)         ## server: a player asked to set sail now
signal chat_received(msg: Dictionary)  ## anyone online: a chat line arrived (chat_log keeps the last few)
signal guest_returned(team: int)       ## host: a player who'd left is sailing their crew again (their island is loaded)
signal guest_rejoining(team: int)      ## host: a player who'd left is back, and loading their way into their crew
signal connection_lost                 ## guest in a match: the connection dropped; trying to get back in
signal guest_waiting(team: int)        ## host: a player lost their connection mid-game; the game waits for them
signal decision_asked(names: String, can_save: bool) ## anyone: they didn't come back in time; what now? (Main asks)
signal decision_made(text: String)     ## anyone: decided (or they're back): what happened

const PORT := 24680
const DualPeer := preload("res://scripts/dual_peer.gd")
## Bump whenever messages change shape, so mismatched builds refuse each other
## politely instead of desyncing.
const PROTOCOL := 13
const MAX_GUESTS := 3
## Messages a guest may send per second before the rest are ignored, and the
## count past which they're sent away. A person clicking sends a handful.
const RATE_LIMIT := 30
const RATE_KICK := 150
## Seconds to wait for a friend's hello before treating them as an old copy.
const LEGACY_WAIT := 3.0
## Longest chat line, and how many recent lines are kept for the screens.
const CHAT_MAX := 200
const CHAT_KEEP := 30
## Guest: how long to keep trying to get back into a match after the
## connection drops (a phone that was locked, a Wi-Fi hiccup), and how often.
const RECONNECT_SECONDS := 120.0
const RECONNECT_EVERY := 3.0
## How long a connection we're leaving stays open to send "I'm leaving".
const LINGER_MSEC := 500

enum Role { NONE, HOST, GUEST }

var role := Role.NONE
## Hosting as a dedicated server, or (on a guest) playing on one.
var dedicated := false
## Guest: why the host sent us away, when it said.
var refusal := ""
## Host: this lobby continues a saved match, so friends rejoin straight into
## their saved crews (no choosing). Guest: the welcome said so.
var resuming := false
## Host: intents nobody may send (a server can switch off pausing).
var blocked_intents := {}
## Guest, connecting to a server: what to ask for in our hello. A Dictionary
## of settings starts a new game there (crews, seats, length, difficulty,
## size), "continue" picks up the server's saved match, and null joins the
## game someone else started. Set after join_game().
var server_request: Variant = null
## Server: decides whether someone who said hello may have a seat, and can
## open a game for them first. Called with their peer id; returns "" to let
## them in, or why not.
var gatekeeper := Callable()
## Guest on a server: the lobby as the server last described it (see
## send_lobby()): {"leader": crew or -1, "seats": [...], "auto": bool}.
var lobby := {}
## Recent chat lines, oldest first: {"name", "team", "text", "side"} (side:
## sent to the sender's 2v2 side only).
var chat_log: Array = []
## Host: per peer, [the second it's counting, messages in that second].
var _rate := {}
## Host: peers being sent away (told why, and disconnected a moment later).
var _leaving := {}
## Host: each friend's peer id -> the crew they sail.
var guests := {}
## Host: peers that have loaded the island and can receive game traffic.
var _in_game := {}
## Host: crews whose friend has picked their makeup in the lobby.
var _chosen := {}
## Host: the game (or the match) is under way, so a friend leaving hands their
## crew to the computer instead of freeing the seat.
var match_started := false
## The GameServer of the running game on this machine, when there is one.
var game_server: GameServer = null
## Host, during a match: crew -> the player id of the player who left it (the
## computer sails it meanwhile). If they come back, they get it again.
var away := {}
## Host: peers back in their crew mid-game, still loading the island (peer -> crew).
var _returning := {}
## Host: peers who said they're leaving on purpose (their crew isn't kept for them).
var _quitting := {}
## Host: when a player loses their connection mid-game, the game waits this
## long, paused, for them to come back; then the others choose: give their
## crew to the computer, keep waiting, or save the game for later. 0: the
## computer takes over at once.
var wait_seconds := 120.0
## Host: saves the game for later and ends it, given the name of who chose
## that. A player's hosted game saves to its online slot (Continue Online
## Match); a dedicated server sets its own, or none if it keeps no saves.
var save_for_later := Callable()
var _waiting := {}          # host: crew -> name of the player the game waits for
var _wait_left := -1.0
var _asked := false         # host: the others have been asked what to do
var _shown_secs := -1
## Guest: the address of the match we're in, to get back into it if the
## connection drops; "" outside a match.
var match_address := ""
## Guest: trying to get back into the match after the connection dropped.
var reconnecting := false
var _address := ""          # guest: what we last connected to
var _reconnect_until := 0.0
var _retry_at := 0.0
var _notice: CanvasLayer = null
var _lingering: Array = []  # [connection, when to close it]: left on purpose, still sending the goodbye
var _notice_label: Label = null
var _notice_sail: Button = null
var _back_in_lobby := false # guest: reconnected into our saved game's lobby
## Checks versions with each friend, and hands the game over when they differ.
var updater: Updater

## The first friend's peer id, or 0 with nobody connected.
var guest_id: int:
	get:
		return int(guests.keys()[0]) if not guests.is_empty() else 0
## Host: every friend has loaded the island.
var guest_in_game: bool:
	get:
		return all_in_game()

func _ready() -> void:
	updater = Updater.new()
	add_child(updater)
	(multiplayer as SceneMultiplayer).peer_packet.connect(updater.on_packet)
	updater.versions_match.connect(_on_versions_match)
	updater.refused.connect(_on_refused)
	multiplayer.connected_to_server.connect(func() -> void: updater.greet(1))
	lobby_changed.connect(func() -> void:
		if _notice_sail != null:
			_notice_sail.visible = _back_in_lobby and i_lead())
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(func() -> void:
		var was := dedicated
		_reset()
		if reconnecting:
			dedicated = was
			return # try again shortly (_process)
		join_failed.emit("Couldn't reach that address."))
	multiplayer.server_disconnected.connect(func() -> void:
		var was := dedicated # kept for the goodbye messages
		_reset()
		dedicated = was
		if match_address != "" and refusal == "":
			_start_reconnecting()
			return
		opponent_left.emit())

func is_online() -> bool:
	return role != Role.NONE

func is_dedicated_host() -> bool:
	return dedicated and role == Role.HOST

## `max_clients` counts everyone connected at once, including copies still
## comparing versions; `bind` limits listening to one of this machine's
## addresses (empty: all of them). With a `web_port`, browsers can join too,
## over WebSockets on that TCP port.
func host_game(port := PORT, max_clients := MAX_GUESTS, bind := "", web_port := -1) -> Error:
	leave()
	var peer: MultiplayerPeer
	if web_port >= 0:
		var dual: MultiplayerPeerExtension = DualPeer.new()
		var err: Error = dual.listen(port, web_port, max_clients, bind)
		if err != OK:
			return err
		peer = dual
	else:
		var enet := ENetMultiplayerPeer.new()
		if bind != "":
			enet.set_bind_ip(bind)
		var err := enet.create_server(port, max_clients)
		if err != OK:
			return err
		peer = enet
	multiplayer.multiplayer_peer = peer
	role = Role.HOST
	save_for_later = _host_save_for_later
	updater.rejoin_address = ""
	return OK

## `address` may carry its own port as "host:port". A ws:// or wss:// address
## is a server's WebSocket, which is how a copy in a web browser connects.
func join_game(address: String) -> Error:
	leave()
	return _connect_to(address)

func _connect_to(address: String) -> Error:
	refusal = ""
	var host := address.strip_edges()
	var peer: MultiplayerPeer
	if host.begins_with("ws://") or host.begins_with("wss://"):
		var ws := WebSocketMultiplayerPeer.new()
		ws.inbound_buffer_size = DualPeer.WEB_OUT_BUFFER # the island and snapshots arrive whole
		ws.max_queued_packets = 4096
		var err := ws.create_client(host)
		if err != OK:
			return err
		peer = ws
	else:
		var port := PORT
		if host.count(":") == 1:
			port = int(host.get_slice(":", 1))
			host = host.get_slice(":", 0)
		if host == "":
			return ERR_INVALID_PARAMETER
		var enet := ENetMultiplayerPeer.new()
		var err := enet.create_client(host, port)
		if err != OK:
			return err
		peer = enet
	multiplayer.multiplayer_peer = peer
	role = Role.GUEST
	_address = address.strip_edges()
	updater.rejoin_address = address.strip_edges()
	updater.relaunch_extra = PackedStringArray()
	return OK

func leave() -> void:
	var peer := multiplayer.multiplayer_peer
	if role == Role.GUEST and peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		# Leaving on purpose: say so, so the host doesn't keep our crew for
		# us. The connection stays open a moment (_linger) so that arrives
		# before the goodbye: a goodbye that comes with it can lose it.
		_rpc_leaving.rpc_id(1)
		peer.poll() # on its way now, in case nothing polls it again (quitting)
		if peer is ENetMultiplayerPeer:
			(peer as ENetMultiplayerPeer).host.flush()
		multiplayer.multiplayer_peer = null
		_lingering.append([peer, Time.get_ticks_msec() + LINGER_MSEC])
		peer = null
	if peer != null and not peer is OfflineMultiplayerPeer:
		peer.close()
	multiplayer.multiplayer_peer = null
	_reset()
	match_address = ""
	_stop_reconnecting()

func _reset() -> void:
	updater.reset()
	role = Role.NONE
	guests.clear()
	_in_game.clear()
	_chosen.clear()
	_rate.clear()
	_leaving.clear()
	match_started = false
	dedicated = false
	resuming = false
	server_request = null
	lobby = {}
	chat_log.clear()
	away.clear()
	_returning.clear()
	_quitting.clear()
	_waiting.clear()
	_wait_left = -1.0
	_asked = false

## Dedicated server: back to an empty lobby for the next match, still
## listening. Anyone connected but not seated (comparing versions,
## downloading) stays connected.
func reopen() -> void:
	guests.clear()
	_in_game.clear()
	_chosen.clear()
	away.clear()
	_returning.clear()
	_quitting.clear()
	_waiting.clear()
	_wait_left = -1.0
	_asked = false
	match_started = false
	resuming = false

## Host: send someone away, telling them why first. The reason travels over
## the updater's raw packets, which every copy since 0.6.1 understands (older
## ones ignore it); the connection closes a moment later, so it arrives.
func kick(id: int, reason: String) -> void:
	if role != Role.HOST or _leaving.has(id):
		return
	_leaving[id] = true
	updater.say_goodbye(id, reason)
	peer_refused.emit(id, reason)
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		if role == Role.HOST and multiplayer.get_peers().has(id):
			multiplayer.multiplayer_peer.disconnect_peer(id))

## Guest: the host said goodbye and why.
func _on_refused(peer: int, reason: String) -> void:
	if role != Role.GUEST or peer != 1:
		return
	_go_away.call_deferred(reason) # not while the network is mid-poll

func _go_away(reason: String) -> void:
	if role != Role.GUEST:
		return
	var was := dedicated # kept for the goodbye messages
	if reconnecting:
		reason = "Couldn't get back into the game: " + reason
	leave()
	dedicated = was
	refusal = reason
	opponent_left.emit()
	join_failed.emit(reason)

# --- waiting for a player who lost their connection (host) -------------------

func _game_on() -> bool:
	return game_server != null and is_instance_valid(game_server) and game_server.started and not game_server.won

## People still playing: the players connected, and a host's own player.
func _people_left() -> int:
	return guests.size() + (0 if dedicated else 1)

func _waiting_names() -> String:
	var names: Array = _waiting.values()
	return " and ".join(names) if names.size() <= 2 else ", ".join(names.slice(0, names.size() - 1)) + " and " + str(names[-1])

## The game stays paused, counting down, until they're back; then everyone
## still playing is asked what to do (the first answer counts).
func _tick_wait(delta: float) -> void:
	if role != Role.HOST or _waiting.is_empty():
		return
	if not _game_on():
		_waiting.clear() # the game ended meanwhile
		_wait_left = -1.0
		_asked = false
		return
	var names := _waiting_names()
	if _asked:
		return
	_wait_left -= delta
	var secs := maxi(ceili(_wait_left), 0)
	if secs != _shown_secs:
		_shown_secs = secs
		game_server.hold(true, "%s lost the connection. Waiting for them to come back (%d:%02d)..." % [names, secs / 60, secs % 60])
	if _wait_left > 0.0:
		return
	_asked = true
	var can_save := save_for_later.is_valid()
	game_server.hold(true, "%s didn't come back in time. Choose what to do." % names)
	for id in guests:
		_rpc_decide.rpc_id(int(id), names, can_save)
	decision_asked.emit(names, can_save)

## Someone on this machine chose: "replace" (the computer sails their crew;
## they can still come back into it), "wait" (another while) or "save" (for
## later, ending the game).
func choose(choice: String) -> void:
	if role == Role.HOST:
		_decide(choice, GameConfig.player_name())
	elif role == Role.GUEST:
		_rpc_choose.rpc_id(1, choice)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_choose(choice: Variant) -> void:
	var team := _sender_team()
	if team < 0 or not _allow() or not choice is String:
		return
	var who := updater.name_of(multiplayer.get_remote_sender_id())
	_decide(choice, who if who != "" else GameConfig.team_name(team))

func _decide(choice: String, who: String) -> void:
	if _waiting.is_empty() or not _asked:
		return # someone else answered first, or they're back
	var names := _waiting_names()
	match choice:
		"replace":
			var teams := _waiting.keys()
			_end_wait("%s gave %s's crew to the computer." % [who, names])
			for t in teams:
				GameConfig.controllers[int(t)] = GameConfig.Ctrl.COMPUTER
				guest_left.emit(int(t)) # Main hands it over
		"wait":
			_asked = false
			_wait_left = wait_seconds
			_shown_secs = -1
			_tell_decided("%s chose to keep waiting for %s." % [who, names])
		"save":
			if not save_for_later.is_valid():
				return
			var save := save_for_later
			_waiting.clear()
			_asked = false
			_wait_left = -1.0
			_tell_decided("%s saved the game for later." % who)
			save.call(who)

func _end_wait(text: String) -> void:
	_waiting.clear()
	_wait_left = -1.0
	_asked = false
	if _game_on():
		game_server.hold(false)
	_tell_decided(text)

## Everyone: the question is settled (text: what happened; "" just closes it).
func _tell_decided(text: String) -> void:
	for id in guests:
		_rpc_decided.rpc_id(int(id), text)
	decision_made.emit(text)

@rpc("authority", "call_remote", "reliable")
func _rpc_decide(names: Variant, can_save: Variant) -> void:
	decision_asked.emit(clean_chat(str(names)).left(80), bool(can_save))

@rpc("authority", "call_remote", "reliable")
func _rpc_decided(text: Variant) -> void:
	decision_made.emit(clean_chat(str(text)))

## A player's hosted game, saved for later: to the host's online slot, which
## Continue Online Match picks up (each friend back in their own crew). The
## friends are told why, then the host goes back to the menu.
func _host_save_for_later(who: String) -> void:
	var gs := game_server
	if gs != null and is_instance_valid(gs):
		GameConfig.save_game(gs.save_state(), "%s, turn %d of game %d" % [GameConfig.match_summary(), gs.turn, GameConfig.match_games + 1])
	for id in guests.keys():
		kick(int(id), "%s saved the game for later. When the host continues it, you come back into your own crew." % who)
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if role != Role.HOST or dedicated:
			return
		leave()
		GameConfig.menu_notice = "Saved for later: Continue Online Match picks it up again."
		get_tree().change_scene_to_file("res://scenes/Menu.tscn"))

# --- getting back in after the connection drops (guest) ---------------------

## The connection to the host or server dropped mid-match, and not because it
## sent us away: keep trying to get back in for a while (the host gives us our
## crew back: see _seat_coming_back()). A notice covers whatever screen this is.
func _start_reconnecting() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if reconnecting:
		_retry_at = now + RECONNECT_EVERY # dropped again while getting back in: same deadline
		return
	reconnecting = true
	_reconnect_until = now + RECONNECT_SECONDS
	_retry_at = now + 0.5
	_show_notice("Lost the connection to the %s. Getting you back in..." % ("server" if dedicated else "host"))
	connection_lost.emit()

func _stop_reconnecting() -> void:
	reconnecting = false
	if _notice != null:
		_notice.queue_free()
		_notice = null
		_notice_label = null
		_notice_sail = null

func _process(delta: float) -> void:
	_linger()
	_tick_wait(delta)
	if not reconnecting:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now > _reconnect_until:
		var was := dedicated
		leave()
		dedicated = was
		refusal = "Lost the connection to the %s and couldn't get back in." % ("server" if was else "host")
		opponent_left.emit()
		return
	if role == Role.NONE and now >= _retry_at:
		_retry_at = now + RECONNECT_EVERY
		var keep := match_address
		var was := dedicated
		if _connect_to(match_address) != OK:
			_reset()
		else:
			server_request = "rejoin" # a server may have saved our game: back into it
		dedicated = was
		match_address = keep

## Leave, and quit once the goodbye has had time to go (see leave()).
func leave_and_quit(code := 0) -> void:
	leave()
	if not _lingering.is_empty():
		await get_tree().create_timer(LINGER_MSEC / 1000.0 + 0.1).timeout
	get_tree().quit(code)

## Connections we've left: keep sending until it's time to close them.
func _linger() -> void:
	for entry in _lingering.duplicate():
		var peer: MultiplayerPeer = entry[0]
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			_lingering.erase(entry) # already closed from the other end
			continue
		peer.poll()
		if Time.get_ticks_msec() >= int(entry[1]):
			peer.close()
			_lingering.erase(entry)

func _show_notice(text: String) -> void:
	if _notice == null:
		_notice = CanvasLayer.new()
		_notice.layer = 100
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.55)
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_STOP # nothing to click while we're away
		_notice.add_child(dim)
		var label := Label.new()
		_notice_label = label
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 26)
		label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
		dim.add_child(label)
		# Leading a saved game we got back into: sail without the others.
		_notice_sail = Button.new()
		_notice_sail.text = "Set Sail Without Them"
		_notice_sail.add_theme_font_size_override("font_size", 22)
		_notice_sail.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_notice_sail.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_notice_sail.offset_top = -120
		_notice_sail.offset_bottom = -60
		_notice_sail.visible = false
		_notice_sail.pressed.connect(request_sail)
		dim.add_child(_notice_sail)
		add_child(_notice)
	_notice_label.text = text

## What to tell a guest whose game just ended without them: the host's own
## reason if it gave one, otherwise `fallback`.
func farewell(fallback: String) -> String:
	return refusal if refusal != "" else fallback

## Host: whether this message's sender is within the rate limit. Someone far
## over it is sent away.
func _allow() -> bool:
	var id := multiplayer.get_remote_sender_id()
	var now := floori(Time.get_ticks_msec() / 1000.0)
	var r: Array = _rate.get(id, [now, 0])
	if int(r[0]) != now:
		r = [now, 0]
	r[1] = int(r[1]) + 1
	_rate[id] = r
	if int(r[1]) == RATE_KICK:
		kick(id, "Disconnected: your copy sent far too many messages.")
	return int(r[1]) <= RATE_LIMIT

## Addresses a friend could use to reach this machine, Tailscale's first.
static func local_addresses() -> Array[String]:
	var tailscale: Array[String] = []
	var lan: Array[String] = []
	for a in IP.get_local_addresses():
		if a.count(".") != 3 or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var parts := a.split(".")
		var second := int(parts[1])
		if parts[0] == "100" and second >= 64 and second <= 127:
			tailscale.append(a) # 100.64.0.0/10 — the range Tailscale hands out
		else:
			lan.append(a)
	return tailscale + lan

static func is_tailscale(address: String) -> bool:
	var parts := address.split(".")
	return parts.size() == 4 and parts[0] == "100" and int(parts[1]) >= 64 and int(parts[1]) <= 127

# --- who sails what (host) ---------------------------------------------------

func peer_for(team: int) -> int:
	for id in guests:
		if int(guests[id]) == team:
			return int(id)
	return 0

## The crew the message's sender sails, or -1 for a stranger.
func _sender_team() -> int:
	if role != Role.HOST:
		return -1
	return int(guests.get(multiplayer.get_remote_sender_id(), -1))

## The first crew a friend can sail: the NAVS on a dedicated server, which has
## no crew of its own; otherwise the Pirates, the NAVS being the host's.
func first_seat() -> int:
	return 0 if is_dedicated_host() else 1

## Crews waiting for a friend: chosen as friends' seats, and nobody in them yet.
func open_seats() -> Array:
	var out := []
	for t in range(first_seat(), GameConfig.team_count):
		if GameConfig.is_friend(t) and peer_for(t) == 0:
			out.append(t)
	return out

func team_in_game(team: int) -> bool:
	var id := peer_for(team)
	return id != 0 and _in_game.has(id)

## Host: this peer has loaded the island.
func in_game(id: int) -> bool:
	return _in_game.has(id)

func all_in_game() -> bool:
	for id in guests:
		if not _in_game.has(id):
			return false
	return true

func has_chosen(team: int) -> bool:
	return _chosen.has(team)

## Every friend's seat is filled, and everyone in one has picked their crew.
func all_seats_ready() -> bool:
	if not open_seats().is_empty():
		return false
	for id in guests:
		if not _chosen.has(int(guests[id])):
			return false
	return true

## Host, in the lobby: give the seats nobody has taken to the computer, so the
## game can start without waiting for more friends.
func fill_open_seats() -> void:
	var model := GameConfig.computer_counts()
	for t in open_seats():
		GameConfig.controllers[t] = GameConfig.Ctrl.COMPUTER
		GameConfig.team_counts[t] = model.duplicate()
	seats_changed.emit()

# --- lobby -----------------------------------------------------------------

## Host: a friend connected. First compare versions (Updater); they get a seat
## once both say the same. A copy from before 0.6.1 never says hello, so after
## a few seconds it gets the old welcome, which checks the protocol itself.
func _on_peer_connected(id: int) -> void:
	if role != Role.HOST:
		return
	if not dedicated and (open_seats().is_empty() if not match_started else away.is_empty() and _returning.is_empty() and guests.size() >= _seats_for_players()):
		# Every crew is spoken for (or the game is under way, and nobody is
		# away who might be coming back): turned away. (A dedicated server
		# compares versions first, so an older copy can still update from
		# it; _admit turns it away afterwards.)
		kick(id, _full_reason())
		return
	updater.greet(id)
	get_tree().create_timer(LEGACY_WAIT).timeout.connect(_legacy_admit.bind(id))

func _on_versions_match(id: int) -> void:
	if role == Role.HOST and not guests.has(id) and not _leaving.has(id):
		if gatekeeper.is_valid():
			var why: String = gatekeeper.call(id)
			if why != "":
				kick(id, why)
				return
		_admit(id)

func _legacy_admit(id: int) -> void:
	if role == Role.HOST and not guests.has(id) and not updater.knows(id) \
			and multiplayer.get_peers().has(id):
		_admit(id)

func _full_reason() -> String:
	if match_started:
		return "A game is already under way there. Try again when it's over."
	return "Every crew there is taken."

func _admit(id: int) -> void:
	if match_started:
		var back := _seat_coming_back(id)
		if back < 0:
			kick(id, _full_reason())
		else:
			_readmit(id, back)
		return
	var team := _seat_for(id)
	if team < 0:
		kick(id, _full_reason())
		return
	guests[id] = team
	var who := updater.player_of(id)
	if who != "":
		GameConfig.seat_owners[team] = who
	if resuming:
		_chosen[team] = true # a saved crew: nothing to choose
	_rpc_welcome.rpc_id(id, {
		"dedicated": dedicated,
		"resume": resuming,
		"protocol": PROTOCOL,
		"version": GameConfig.version(),
		"seed": GameConfig.island_seed,
		"length": GameConfig.length,
		"target": GameConfig.team_target,
		"teams": GameConfig.team_count,
		"partner": GameConfig.partner,
		"team": team,
		"ctrl": GameConfig.resolved_controllers(),
		"navs": GameConfig.nav_counts,
		"royale": GameConfig.royale_state(),
		"turn": GameConfig.turn_seconds,
	})
	guest_connected.emit()
	seats_changed.emit()
	if resuming:
		guest_ready.emit({})

## The seat for someone arriving: in a saved match, the crew they sailed
## before if it's free; otherwise the first free crew nobody else owns, and
## failing that any free crew (a friend on a new computer). -1: none free.
func _seat_for(id: int) -> int:
	var seats := open_seats()
	if seats.is_empty():
		return -1
	var me := updater.player_of(id)
	if me != "":
		for t in seats:
			if str(GameConfig.seat_owners.get(t, "")) == me:
				return t
	for t in seats:
		if not GameConfig.seat_owners.has(t):
			return t
	return seats[0]

## Crews players can sail in this match (the rest are the computer's for good).
func _seats_for_players() -> int:
	var n := 0
	for t in range(first_seat(), GameConfig.team_count):
		if GameConfig.seat_owners.has(t):
			n += 1
	return n

## During a match: the crew this newcomer sailed before they lost their
## connection, or -1. Someone whose old connection is still hanging on (the
## server hasn't noticed it die) takes their crew over from it.
func _seat_coming_back(id: int) -> int:
	var me := updater.player_of(id)
	if me == "":
		return -1
	for t in away:
		if str(away[t]) == me and peer_for(int(t)) == 0:
			return int(t)
	for old in guests.keys():
		var t := int(guests[old])
		if int(old) != id and str(GameConfig.seat_owners.get(t, "")) == me:
			# Their old connection is still here: the new one takes its place
			# (no hand-over to the computer and back), and the old one is
			# dropped. Its goodbye, when it comes, finds no seat to free.
			var gone := int(old)
			guests.erase(gone)
			_in_game.erase(gone)
			_returning.erase(gone)
			_leaving[gone] = true
			multiplayer.multiplayer_peer.disconnect_peer(gone)
			return t
	return -1

## A player is back in the crew they sailed. Mid-game they land on the island
## as it stands (everyone exactly where they are), and take the helm back from
## the computer once it's loaded; between games they go to the coaching.
func _readmit(id: int, team: int) -> void:
	away.erase(team)
	guests[id] = team
	var cfg := _island_cfg()
	var ctrl: Array = cfg.ctrl
	ctrl[team] = GameConfig.Ctrl.FRIEND
	cfg.merge({"protocol": PROTOCOL, "version": GameConfig.version(), "dedicated": dedicated, "team": team,
		"target": GameConfig.team_target, "counts": GameConfig.team_counts, "match": GameConfig.match_state()})
	var gs := game_server
	if gs != null and is_instance_valid(gs) and not gs.won:
		_returning[id] = team
		cfg["people"] = gs.save_state().people
		_rpc_rejoin.rpc_id(id, cfg)
		guest_rejoining.emit(team)
	else:
		GameConfig.controllers[team] = GameConfig.Ctrl.FRIEND
		if team < GameConfig.match_ready.size():
			GameConfig.match_ready[team] = false
		cfg["between"] = true
		_rpc_rejoin.rpc_id(id, cfg)
		guest_rejoining.emit(team)
		guest_returned.emit(team)
		send_match()
		match_changed.emit()
	seats_changed.emit()

## Guest -> host: I'm leaving on purpose (not a dropped connection).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_leaving() -> void:
	if role == Role.HOST:
		_quitting[multiplayer.get_remote_sender_id()] = true

## Host -> a player coming back: the island as it is now, and your crew.
@rpc("authority", "call_remote", "reliable")
func _rpc_rejoin(cfg: Dictionary) -> void:
	if int(cfg.get("protocol", -1)) != PROTOCOL:
		leave()
		join_failed.emit("The server now has version %s of the game and you have %s." % [str(cfg.get("version", "another")), GameConfig.version()])
		return
	dedicated = bool(cfg.get("dedicated", false))
	resuming = false
	var saved_match: Variant = cfg.get("match")
	if saved_match is Dictionary:
		GameConfig.apply_match_state(saved_match)
	_apply_island(cfg)
	GameConfig.team_target = clampi(int(cfg.get("target", GameConfig.team_target)), 1, GameConfig.MAX_TEAM_SIZE)
	var counts: Variant = cfg.get("counts", [])
	if counts is Array:
		for t in mini(counts.size(), GameConfig.MAX_TEAMS):
			GameConfig.team_counts[t] = GameConfig.sanitize_counts(counts[t])
	GameConfig.my_team = clampi(int(cfg.get("team", GameConfig.my_team)), 0 if dedicated else 1, GameConfig.team_count - 1)
	GameConfig.mode = GameConfig.Mode.GUEST
	GameConfig.configured = true
	match_address = _address
	_stop_reconnecting()
	if bool(cfg.get("between", false)):
		get_tree().change_scene_to_file("res://scenes/Coaching.tscn")
		return
	var people: Variant = cfg.get("people")
	GameConfig.resume = {"people": _clean_people(people)} if people is Array else {}
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_peer_disconnected(id: int) -> void:
	var name := updater.name_of(id)
	# Leaving on purpose, or sent away: nobody waits for them.
	var quit := _quitting.has(id) or _leaving.has(id)
	updater.peer_gone(id)
	_rate.erase(id)
	_leaving.erase(id)
	_quitting.erase(id)
	if role != Role.HOST or not guests.has(id):
		return
	var team := int(guests[id])
	guests.erase(id)
	_in_game.erase(id)
	_returning.erase(id)
	_chosen.erase(team)
	if match_started:
		var owner := str(GameConfig.seat_owners.get(team, ""))
		if owner != "" and not quit:
			away[team] = owner # lost their connection: theirs again if they come back
			if wait_seconds > 0.0 and _game_on() and _people_left() > 0:
				# Mid-game, with others still playing: everyone waits for them.
				_waiting[team] = name if name != "" else GameConfig.team_name(team)
				_wait_left = wait_seconds
				_shown_secs = -1
				if _asked:
					_asked = false
					_tell_decided("") # a choice being asked about someone else: asked again, with them too
				guest_waiting.emit(team)
				seats_changed.emit()
				return
		# Mid-game or between games: the computer sails their crew from now on.
		GameConfig.controllers[team] = GameConfig.Ctrl.COMPUTER
		if team < GameConfig.match_ready.size():
			GameConfig.match_ready[team] = true
		guest_left.emit(team)
		# They might have been the one everyone was waiting for. (A dedicated
		# server with nobody left has no one to start a game for: it reopens.)
		if (game_server == null or game_server.won) and not (dedicated and guests.is_empty()):
			_after_ready()
	seats_changed.emit()

## Host -> guest: here's the island, the rules, and the crew you'll sail.
@rpc("authority", "call_remote", "reliable")
func _rpc_welcome(cfg: Dictionary) -> void:
	if reconnecting:
		if bool(cfg.get("resume", false)):
			# Everyone had gone, so the server saved our game, and has opened
			# it again for us: we sail as soon as the server says so (alone,
			# at once; with friends, once they're back or the leader sets sail).
			reconnecting = false
			_back_in_lobby = true
			_show_notice("Back on the server, in your saved game. Waiting for the others to come back...")
		else:
			# Back in, but to a new lobby: the match we were in is over.
			var was := dedicated
			leave()
			dedicated = was
			refusal = "The match ended while you were away."
			opponent_left.emit()
			return
	if int(cfg.get("protocol", -1)) != PROTOCOL:
		leave()
		join_failed.emit("Your friend has version %s of the game and you have %s.\nYou both need the same version: download it from the same release." % [
			str(cfg.get("version", "an older one")), GameConfig.version()])
		return
	dedicated = bool(cfg.get("dedicated", false))
	resuming = bool(cfg.get("resume", false))
	_apply_island(cfg)
	GameConfig.team_target = clampi(int(cfg.get("target", GameConfig.DEFAULT_TEAM_SIZE)), 1, GameConfig.MAX_TEAM_SIZE)
	GameConfig.nav_counts = GameConfig.sanitize_counts(cfg.get("navs", {}))
	# A dedicated server's players sail any crew, the NAVS included.
	GameConfig.my_team = clampi(int(cfg.get("team", 1)), 0 if dedicated else 1, GameConfig.team_count - 1)
	GameConfig.team_counts[GameConfig.my_team] = GameConfig.balanced_counts(GameConfig.team_target)
	joined.emit()

## The island and the crews, as the host has them.
func _apply_island(cfg: Dictionary) -> void:
	GameConfig.island_seed = int(cfg.get("seed", 0))
	GameConfig.length = clampi(int(cfg.get("length", 1)), 0, 2) as TerrainGrid.Length
	GameConfig.team_count = clampi(int(cfg.get("teams", 2)), GameConfig.MIN_TEAMS, GameConfig.MAX_TEAMS)
	var ctrl: Variant = cfg.get("ctrl")
	if ctrl is Array and ctrl.size() == GameConfig.MAX_TEAMS:
		GameConfig.controllers = ctrl.map(func(v: Variant) -> int: return clampi(int(v), 0, GameConfig.Ctrl.FRIEND))
	GameConfig.partner = clampi(int(cfg.get("partner", GameConfig.FREE_FOR_ALL)), GameConfig.FREE_FOR_ALL, GameConfig.MAX_TEAMS - 1)
	if cfg.get("royale") is Dictionary:
		GameConfig.apply_royale(cfg.royale)
	var turn: Variant = cfg.get("turn")
	if turn is int or turn is float:
		GameConfig.turn_seconds = clampi(int(turn), 0, 3600)
	var names: Variant = cfg.get("names", [])
	for t in GameConfig.MAX_TEAMS:
		GameConfig.team_names[t] = GameConfig.sanitize_names(names[t]) if names is Array and t < names.size() else []

## Guest: I've chosen my crew.
func send_ready(counts: Dictionary) -> void:
	_rpc_names.rpc_id(1, GameConfig.my_crew_names()) # reliable and in order: there before the ready
	_rpc_ready.rpc_id(1, counts)

## Guest, regular game: the names from my Your Crew (no skills), for my
## sailors to land with. The host checks them and passes them on with the
## island; anyone they don't cover gets the usual name.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_names(names: Variant) -> void:
	var team := _sender_team()
	if team < 0 or team >= GameConfig.MAX_TEAMS or not _allow() or _chosen.has(team) or match_started:
		return
	GameConfig.team_names[team] = GameConfig.sanitize_names(names)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_ready(counts: Variant) -> void:
	var team := _sender_team()
	if team < 0 or not _allow() or _chosen.has(team) or match_started:
		return
	var clean := GameConfig.sanitize_counts(counts)
	if GameConfig.team_size(clean) != GameConfig.team_target:
		return
	GameConfig.team_counts[team] = clean
	_chosen[team] = true
	seats_changed.emit()
	guest_ready.emit(clean)

## Guest, in a Battle Royale: here's the crew I'm bringing (my trained crew
## from single player). The host checks it and seats it.
func send_crew(people: Array) -> void:
	_rpc_crew.rpc_id(1, people)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_crew(people: Variant) -> void:
	var team := _sender_team()
	if team < 0 or not _allow() or _chosen.has(team) or match_started or not GameConfig.battle_royale:
		return
	var clean := GameConfig.sanitize_crew(people)
	if clean.is_empty():
		return
	GameConfig._fit_match()
	GameConfig.match_crews[team] = clean
	GameConfig.team_counts[team] = GameConfig.counts_of(clean)
	_chosen[team] = true
	seats_changed.emit()
	guest_ready.emit(GameConfig.team_counts[team])

## Server -> its players in the lobby: each crew, who sails it (a player by
## name, the computer, or nobody yet) and whether they've chosen, and which
## crew's player leads (started the game, so may set sail early).
func send_lobby(state: Dictionary) -> void:
	for id in guests:
		_rpc_lobby.rpc_id(int(id), state)

@rpc("authority", "call_remote", "reliable")
func _rpc_lobby(state: Dictionary) -> void:
	lobby = state
	lobby_changed.emit()

## Guest on a server: whether the lobby says we lead the game.
func i_lead() -> bool:
	return int(lobby.get("leader", -1)) == GameConfig.my_team and GameConfig.my_team >= 0

## Guest on a server, leading the game: set sail now, with the computer in
## the seats nobody has taken. The server checks it's really the leader asking.
func request_sail() -> void:
	_rpc_sail.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_sail() -> void:
	if _sender_team() < 0 or not _allow() or match_started:
		return
	sail_requested.emit(multiplayer.get_remote_sender_id())

## Host: everyone's chosen — land on the island.
func start_match() -> void:
	match_started = true
	var model := GameConfig.computer_counts()
	for t in range(first_seat(), GameConfig.team_count):
		if GameConfig.is_computer(t):
			GameConfig.team_counts[t] = model.duplicate()
	if GameConfig.battle_royale and not resuming:
		# Every crew lands as its player trained it (the host's own too); the
		# guests need them all to build the same island.
		GameConfig._fit_match()
		if GameConfig.mode == GameConfig.Mode.HOST and GameConfig.match_crews[Character.Team.NAVS].is_empty():
			GameConfig.match_crews[Character.Team.NAVS] = GameConfig.sanitize_crew(GameConfig.my_br_crew())
	if not GameConfig.battle_royale and not resuming:
		# Regular game: each player's Your Crew names (the host's own too);
		# computer crews and empty seats get the usual names.
		for t in GameConfig.MAX_TEAMS:
			if not _chosen.has(t):
				GameConfig.team_names[t] = []
		if GameConfig.mode == GameConfig.Mode.HOST and not dedicated:
			GameConfig.team_names[Character.Team.NAVS] = GameConfig.my_crew_names()
	var cfg := _island_cfg()
	cfg["counts"] = GameConfig.team_counts
	if GameConfig.battle_royale and not resuming:
		cfg["match"] = GameConfig.match_state()
	if resuming:
		# A saved match: the guests need the coached crews, and for a game
		# saved partway through, everyone exactly as they were.
		cfg["match"] = GameConfig.match_state()
		if not GameConfig.resume.is_empty():
			cfg["people"] = GameConfig.resume.get("people", [])
		resuming = false
	for id in guests:
		cfg["team"] = int(guests[id])
		_rpc_start.rpc_id(int(id), cfg)
	GameConfig.configured = true
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _island_cfg() -> Dictionary:
	return {"seed": GameConfig.island_seed, "length": GameConfig.length,
		"teams": GameConfig.team_count, "ctrl": GameConfig.resolved_controllers(), "partner": GameConfig.partner,
		"royale": GameConfig.royale_state(), "names": GameConfig.team_names, "turn": GameConfig.turn_seconds}

@rpc("authority", "call_remote", "reliable")
func _rpc_start(cfg: Dictionary) -> void:
	_back_in_lobby = false
	_stop_reconnecting() # the notice, if we got back in this way
	var saved_match: Variant = cfg.get("match")
	if saved_match is Dictionary:
		GameConfig.apply_match_state(saved_match)
	GameConfig.resume = {}
	var people: Variant = cfg.get("people")
	if people is Array and not people.is_empty():
		GameConfig.resume = {"people": _clean_people(people)}
	_apply_island(cfg)
	var counts: Variant = cfg.get("counts", [])
	if counts is Array:
		for t in mini(counts.size(), GameConfig.MAX_TEAMS):
			GameConfig.team_counts[t] = GameConfig.sanitize_counts(counts[t])
	GameConfig.my_team = clampi(int(cfg.get("team", GameConfig.my_team)), 0 if dedicated else 1, GameConfig.team_count - 1)
	GameConfig.mode = GameConfig.Mode.GUEST
	GameConfig.configured = true
	match_address = _address # a match from here on: get back into it if the connection drops
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

## A saved game's people as the host sent them: only well-formed entries.
static func _clean_people(raw: Array) -> Array:
	var out := []
	for p in raw.slice(0, 40):
		if p is Dictionary and p.get("stats") is Dictionary and p.get("cell") is Vector2i:
			var stats: Dictionary = p.stats
			if stats.has("kind") and stats.has("name"):
				out.append({"stats": stats, "team": clampi(int(p.get("team", 0)), 0, GameConfig.MAX_TEAMS - 1), "cell": p.cell})
	return out

## Guest: my island is built; start sending me the game.
func report_in_game() -> void:
	_rpc_in_game.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_in_game() -> void:
	if _sender_team() < 0 or not _allow():
		return
	var id := multiplayer.get_remote_sender_id()
	_in_game[id] = true
	if _returning.has(id):
		var team := int(_returning[id])
		_returning.erase(id)
		GameConfig.controllers[team] = GameConfig.Ctrl.FRIEND
		guest_returned.emit(team) # Main takes the helm back from the computer
		if _waiting.has(team):
			var back := str(_waiting[team])
			_waiting.erase(team)
			if _waiting.is_empty():
				_end_wait("%s is back. Play on!" % back)
	if game_server:
		game_server.on_guest_in_game()

# --- between games of a match ---------------------------------------------

## Host -> guests: every crew, the score, coaching left, who's ready.
func send_match() -> void:
	if role != Role.HOST:
		return
	for id in guests:
		_rpc_match.rpc_id(int(id), GameConfig.match_state())
	if GameConfig.mode == GameConfig.Mode.HOST:
		# A campaign: the match as it stands, ready to continue another day.
		# Saved after every game and again after each coaching session or
		# rename, so a match left from the coaching screen keeps them.
		# (A dedicated server saves its own, when it's been asked to.)
		GameConfig.save_match()

@rpc("authority", "call_remote", "reliable")
func _rpc_match(state: Dictionary) -> void:
	GameConfig.apply_match_state(state)
	match_changed.emit()

## Guest -> host: my coaching for this round, one pick per person (index ->
## pick). The host rolls every try and sends the results back with the match.
func send_coaching_plan(plan: Dictionary) -> void:
	_rpc_coach_plan.rpc_id(1, plan)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_coach_plan(plan: Variant) -> void:
	var team := _sender_team()
	if team < 0 or not _allow() or not plan is Dictionary:
		return
	if not GameConfig.coach_plan_in_match(team, plan):
		return
	var took: bool = GameConfig.match_note[team].any(func(r: Variant) -> bool: return r is Dictionary and bool(r.get("ok", false)))
	_rpc_sfx.rpc_id(multiplayer.get_remote_sender_id(), AudioManifest.COACH_SUCCESS if took else AudioManifest.COACH_FAIL)
	send_match()
	match_changed.emit()

## Guest -> host: rename one of my crew.
func send_rename(index: int, name: String) -> void:
	_rpc_rename.rpc_id(1, index, name)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_rename(index: Variant, name: Variant) -> void:
	var team := _sender_team()
	if team >= 0 and _allow() and index is int and name is String:
		GameConfig.rename_in_match(team, index, name)
		send_match()
		match_changed.emit()

## Anyone: done coaching, ready for the next island. When every player is,
## the host rolls a new island and everyone lands on it with their coached crews.
func ready_for_next() -> void:
	if role == Role.HOST:
		GameConfig.match_ready[Character.Team.NAVS] = true
		_after_ready()
	elif role == Role.GUEST:
		_rpc_ready_next.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_ready_next() -> void:
	var team := _sender_team()
	if team < 0 or not _allow() or team >= GameConfig.match_ready.size():
		return
	GameConfig.match_ready[team] = true
	_after_ready()

## Dedicated server: the wait between games is over. Anyone still coaching is
## taken to the next island with what they've done so far.
func force_next() -> void:
	if role != Role.HOST or not match_started:
		return
	for t in GameConfig.match_ready.size():
		GameConfig.match_ready[t] = true
	_after_ready()

func _after_ready() -> void:
	if role != Role.HOST:
		return
	if GameConfig.br_over():
		send_match() # every round played: there's no next island
		match_changed.emit()
		return
	if not GameConfig.all_ready():
		send_match()
		match_changed.emit()
		return
	for t in GameConfig.match_ready.size():
		GameConfig.match_ready[t] = false
	GameConfig.island_seed = randi()
	_in_game.clear()
	var cfg := _island_cfg()
	cfg["match"] = GameConfig.match_state()
	for id in guests:
		_rpc_next.rpc_id(int(id), cfg)
	GameConfig.configured = true
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

@rpc("authority", "call_remote", "reliable")
func _rpc_next(cfg: Dictionary) -> void:
	_apply_island(cfg)
	GameConfig.apply_match_state(cfg.get("match", {}))
	GameConfig.configured = true
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# --- chat -------------------------------------------------------------------

## Say something to everyone, or (2v2, `to_side`) to our side only. A guest
## sends it to the host or server, which passes it on; a host passes on its
## own (it sails the NAVS).
func say(text: String, to_side := false) -> void:
	var clean := clean_chat(text)
	if clean == "":
		return
	if role == Role.HOST and not dedicated:
		_pass_on(Character.Team.NAVS, GameConfig.player_name(), clean, to_side)
	elif role == Role.GUEST:
		_rpc_say.rpc_id(1, clean, to_side)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_say(text: Variant, to_side: Variant) -> void:
	var team := _sender_team()
	if team < 0 or not _allow() or not text is String:
		return
	var clean := clean_chat(text)
	if clean == "":
		return
	var who := updater.name_of(multiplayer.get_remote_sender_id())
	_pass_on(team, who if who != "" else GameConfig.team_name(team), clean, to_side is bool and to_side)

## Host or server: hand a line to everyone it's for (and show it here, when a
## host's own crew is one of them).
func _pass_on(team: int, who: String, text: String, to_side: bool) -> void:
	var msg := {"name": who, "team": team, "text": text, "side": to_side}
	for id in guests:
		if not to_side or _same_side(int(guests[id]), team):
			_rpc_heard.rpc_id(int(id), msg)
	if not dedicated and (not to_side or _same_side(Character.Team.NAVS, team)):
		_hear(msg)

func _same_side(a: int, b: int) -> bool:
	var sides := GameConfig.sides()
	return a == b or (not sides.is_empty() and a < sides.size() and b < sides.size() and int(sides[a]) == int(sides[b]))

@rpc("authority", "call_remote", "reliable")
func _rpc_heard(msg: Dictionary) -> void:
	_hear({"name": GameConfig.clean_name(str(msg.get("name", ""))), "team": clampi(int(msg.get("team", 0)), 0, GameConfig.MAX_TEAMS - 1),
		"text": clean_chat(str(msg.get("text", ""))), "side": bool(msg.get("side", false))})

func _hear(msg: Dictionary) -> void:
	chat_log.append(msg)
	if chat_log.size() > CHAT_KEEP:
		chat_log.remove_at(0)
	chat_received.emit(msg)

## A chat line fit to show: one line, printable, no BBCode, at most CHAT_MAX.
static func clean_chat(raw: String) -> String:
	var out := ""
	for ch in raw.left(CHAT_MAX * 2):
		var code := ch.unicode_at(0)
		if code >= 32 and code != 127 and not ch in ["[", "]"]:
			out += ch
	return out.strip_edges().left(CHAT_MAX)

# --- in-game traffic -------------------------------------------------------

## Guest -> host: something my crew wants to do. The host decides.
func send_intent(kind: String, args: Array) -> void:
	if role != Role.GUEST:
		return # reconnecting: nobody to tell
	_rpc_intent.rpc_id(1, kind, args)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_intent(kind: Variant, args: Variant) -> void:
	var team := _sender_team()
	if team < 0 or not _allow():
		return
	if not (kind is String and args is Array) or args.size() > 2 or blocked_intents.has(kind):
		return
	if game_server:
		game_server.intent(team, kind, args)

## Host -> one guest: the game as their crew's screen should show it.
func send_state(team: int, state: Dictionary) -> void:
	var id := peer_for(team)
	if id != 0 and _in_game.has(id):
		_rpc_state.rpc_id(id, state)

@rpc("authority", "call_remote", "reliable")
func _rpc_state(state: Dictionary) -> void:
	if game_server:
		game_server.apply_state(state)

## Host -> the guest sailing `team`: play this sound.
func send_sfx(path: String, team: int) -> void:
	var id := peer_for(team)
	if id != 0 and _in_game.has(id):
		_rpc_sfx.rpc_id(id, path)

@rpc("authority", "call_remote", "reliable")
func _rpc_sfx(path: String) -> void:
	# Only paths from our own manifest are ever played.
	if path.begins_with("res://assets/audio/"):
		AudioManager.play(path)
