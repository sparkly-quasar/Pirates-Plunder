class_name ServerFinder
extends Node

## Finds Pirates Plunder servers for the Play on a Server screen.
##
## Tailscale doesn't carry the broadcasts a game would normally use to find
## others on the network, so this asks the Tailscale app on this computer
## which of your machines are online (`tailscale status --json`, which lists
## machines friends have shared with you too), then asks each one, with one
## small UDP message, whether it runs a server. A server answers on its
## STATUS port, the game's port plus one (24681), with its name, version and
## what it's doing: free, a game being set up, or a game under way. Addresses
## typed by hand are asked the same way.
##
## A machine that doesn't answer over UDP is ALSO asked over TCP: a
## WebSocket to the same port number, where servers answer browsers' lists
## (scripts/web_status.gd). UDP can stop getting through while TCP still
## does: Docker Desktop on a Mac once stopped forwarding a server's UDP status
## port, though its game port and TCP ports kept working, until the container
## was restarted. Such a server is still listed (its "via" is "tcp").
##
## In a WEB BROWSER none of that is possible (no UDP, no Tailscale app to ask),
## and there's only one server to find anyway: the one the page came from.
## The browser asks it the same question over a WebSocket to its status port
## (see web_urls() and scripts/web_status.gd).
##
## The question is padded to QUERY_SIZE bytes, and a server's answer is kept
## smaller than that, so nobody can use a server to flood a third party with
## answers bigger than what they sent.

## A reply, possibly again with fresher news (servers are asked every few
## seconds while the screen is open). See parse_reply() for its keys, plus
## "address" (what to join), "machine" (its Tailscale name, or what was typed)
## and "seen" (when it last answered).
signal found(server: Dictionary)
## Tailscale's list was read: "" if it was, else why there's no list.
signal scanned(note: String)
## A server's Hall of Fame came back (ask_board()): `server` is its entry in
## servers(), `board` {rows: [[rank, name, key, games, wins, titles, aboard,
## captures]], me: the asker's own row if not in rows, or [], players}.
signal board_found(server: Dictionary, board: Dictionary)

const QUERY_MAGIC := "PPQ1"
const REPLY_MAGIC := "PPS1"
const BOARD_MAGIC := "PPH1" ## a Hall of Fame answer
const BOARD_ASK := 0x48 ## "H" in byte 14 of a question: the Hall of Fame, please (older servers ignore it)
const QUERY_SIZE := 512
const REPLY_LIMIT := 480
const STATUS_OFFSET := 1
## Ask every known machine this often, and forget servers silent this long.
const ASK_EVERY := 4.0
const FORGET_AFTER := 13.0
## A machine silent over UDP this long is asked over TCP too; one whose TCP
## status port didn't take (no server there, most often) is tried again after
## TCP_RETRY.
const TCP_AFTER := 2.0
const TCP_RETRY := 20.0

var _udp := PacketPeerUDP.new()
var _thread: Thread = null
var _targets := {}   # ip -> {"machine": name, "port": game port, "typed": bool}
var _pending := {}   # resolver id -> [text, port]
var _servers := {}   # ip -> the last reply, as emitted
var _ask_left := 0.0
var _retries := 0
var _added := {}     # ip -> when it was first asked
var _udp_heard := {} # ip -> when it last answered over UDP
var _tcp := {}       # ip -> {"ws": WebSocketPeer or null, "next": when to try again, "ask": when to ask next}
## In a browser: the page's server, {game, status, machine}, and the
## WebSocket asking it.
var _web := {}
var _web_ws: WebSocketPeer = null
var _web_retry := 0.0

func _ready() -> void:
	if not OS.has_feature("web"):
		_udp.bind(0)

func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
	_udp.close()
	if _web_ws != null:
		_web_ws.close()
	for ip in _tcp:
		if _tcp[ip].ws != null:
			_tcp[ip].ws.close()

## Read Tailscale's list of machines (in the background) and ask each one.
## This computer is asked as well, at 127.0.0.1, for a server running here.
func scan() -> void:
	if OS.has_feature("web"):
		watch_web(web_urls())
		scanned.emit("")
		return
	_add_target("127.0.0.1", Net.PORT, "This computer", false)
	if _thread != null:
		return
	_thread = Thread.new()
	_thread.start(_read_tailscale)

## Ask an address typed by hand ("host" or "host:port").
func look_up(text: String) -> String:
	var host := text.strip_edges()
	var port := Net.PORT
	if host.count(":") == 1:
		port = int(host.get_slice(":", 1))
		host = host.get_slice(":", 0)
	if host == "" or port <= 0 or port >= 65535:
		return "That doesn't look like an address."
	if host.is_valid_ip_address():
		_add_target(host, port, text.strip_edges(), true)
		return ""
	_pending[IP.resolve_hostname_queue_item(host, IP.TYPE_IPV4)] = [text.strip_edges(), port]
	return ""

## Servers heard from lately, newest news, one per server (a server reached
## two ways, say by its Tailscale address and as 127.0.0.1, appears once).
func servers() -> Array:
	var by_id := {}
	for ip in _servers:
		var s: Dictionary = _servers[ip]
		var key := str(s.get("id", ip))
		if not by_id.has(key) or (str(by_id[key].address).begins_with("127.") and not ip.begins_with("127.")):
			by_id[key] = s
	var out := by_id.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.machine).naturalnocasecmp_to(str(b.machine)) < 0)
	return out

func _add_target(ip: String, port: int, machine: String, typed: bool) -> void:
	_targets[ip] = {"machine": machine, "port": port, "typed": typed}
	if not _added.has(ip):
		_added[ip] = _seconds()
	_ask(ip)
	_retries = 2 # a lost packet on a busy network shouldn't hide a server

func _ask(ip: String) -> void:
	_udp.set_dest_address(ip, int(_targets[ip].port) + STATUS_OFFSET)
	_udp.put_packet(query_packet())

func _process(delta: float) -> void:
	if not _web.is_empty():
		_ask_web(delta)
		return
	if _thread != null and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		var note := str(result.get("note", ""))
		if result.has("json"):
			var listed := peers_from_status(str(result.json))
			note = str(listed.note)
			for p in listed.peers:
				_add_target(str(p.ip), Net.PORT, str(p.name), false)
		scanned.emit(note)
	for id in _pending.keys():
		match IP.get_resolve_item_status(id):
			IP.RESOLVER_STATUS_DONE:
				var ip := IP.get_resolve_item_address(id)
				if ip != "":
					_add_target(ip, int(_pending[id][1]), str(_pending[id][0]), true)
				_pending.erase(id)
				IP.erase_resolve_item(id)
			IP.RESOLVER_STATUS_ERROR:
				_pending.erase(id)
				IP.erase_resolve_item(id)
	_ask_left -= delta
	if _ask_left <= 0.0:
		_ask_left = 0.6 if _retries > 0 else ASK_EVERY
		_retries = maxi(_retries - 1, 0)
		for ip in _targets:
			_ask(ip)
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		if _targets.has(ip) and _take_packet(ip, packet, "udp"):
			_udp_heard[ip] = _seconds()
	var now := _seconds()
	_ask_tcp(now)
	for ip in _servers.keys():
		if now - float(_servers[ip].seen) > FORGET_AFTER:
			_servers.erase(ip)

static func _seconds() -> float:
	return Time.get_ticks_msec() / 1000.0

## A packet from `ip`'s status port, over UDP or TCP (`via`): a Hall of Fame
## goes to board_found, an answer to the list. True if it was one of those.
func _take_packet(ip: String, packet: PackedByteArray, via: String) -> bool:
	var board := parse_board_reply(packet)
	if not board.is_empty():
		if _servers.has(ip):
			board_found.emit(_servers[ip], board)
		return true
	var reply := parse_reply(packet)
	if reply.is_empty():
		return false
	var t: Dictionary = _targets[ip]
	reply["machine"] = str(t.machine)
	var port := int(reply.port)
	# What to join: as typed (a name keeps working if its address changes),
	# else the address that answered. Over TCP too: the game itself is still
	# joined over UDP (ENet), which kept working where the status port didn't.
	reply["address"] = str(t.machine) if t.typed else (ip if port == Net.PORT else "%s:%d" % [ip, port])
	reply["seen"] = _seconds()
	reply["via"] = via
	_servers[ip] = reply
	found.emit(reply)
	return true

## Asks over TCP the machines that have been silent over UDP for TCP_AFTER
## (each keeps one WebSocket open while it answers, asked every ASK_EVERY),
## and stops once UDP answers again.
func _ask_tcp(now: float) -> void:
	for ip in _targets:
		if now - float(_udp_heard.get(ip, -1e9)) < FORGET_AFTER or now - float(_added.get(ip, now)) < TCP_AFTER:
			if _tcp.has(ip):
				if _tcp[ip].ws != null:
					_tcp[ip].ws.close()
				_tcp.erase(ip)
			continue
		if not _tcp.has(ip):
			_tcp[ip] = {"ws": null, "next": 0.0, "ask": 0.0}
		var t: Dictionary = _tcp[ip]
		if t.ws == null:
			if now < float(t.next):
				continue
			var ws := WebSocketPeer.new()
			if ws.connect_to_url("ws://%s:%d" % [ip, int(_targets[ip].port) + STATUS_OFFSET]) != OK:
				t.next = now + TCP_RETRY
				continue
			t.ws = ws
			t.ask = 0.0
		var peer: WebSocketPeer = t.ws
		peer.poll()
		match peer.get_ready_state():
			WebSocketPeer.STATE_CLOSED:
				t.ws = null
				t.next = now + TCP_RETRY
			WebSocketPeer.STATE_OPEN:
				if now >= float(t.ask):
					t.ask = now + ASK_EVERY
					peer.send(query_packet())
				while peer.get_available_packet_count() > 0:
					_take_packet(ip, peer.get_packet(), "tcp")

# --- in a web browser ---------------------------------------------------------

## Where a copy in a browser finds its server, from the page's own address:
## {"game": WebSocket URL to play, "status": WebSocket URL to ask what it's
## doing, "machine": what to call it}. Normally the page's own host, with the
## game at /ws and the status at /status (the server package's web server
## passes those through). ?server=host:port points it at a server's ports
## directly instead (the game's TCP port, and the status port one above).
static func web_urls() -> Dictionary:
	var href := str(JavaScriptBridge.eval("window.location.href", true)) if OS.has_feature("web") else ""
	return urls_for_page(href)

static func urls_for_page(href: String) -> Dictionary:
	var secure := href.begins_with("https:")
	var scheme := "wss://" if secure else "ws://"
	var rest := href.get_slice("://", 1)
	var host := rest.get_slice("/", 0).get_slice("?", 0).get_slice("#", 0)
	var query := href.get_slice("?", 1).get_slice("#", 0) if href.contains("?") else ""
	# On https the browser only allows wss://, and the server's own ports
	# speak plain ws://, so a page there (behind `tailscale serve` or Caddy)
	# always goes through its own host's /ws and /status. That's also where
	# the server's / sends it, with a ?server= meant for plain http.
	if secure:
		query = ""
	for pair in query.split("&", false):
		if pair.get_slice("=", 0) == "server":
			var direct := pair.get_slice("=", 1).uri_decode().strip_edges()
			var h := direct
			var p := Net.PORT
			if direct.count(":") == 1:
				h = direct.get_slice(":", 0)
				p = int(direct.get_slice(":", 1))
			if h != "" and p > 0 and p < 65535:
				return {"game": "%s%s:%d" % [scheme, h, p], "status": "%s%s:%d" % [scheme, h, p + STATUS_OFFSET], "machine": h}
	return {"game": scheme + host + "/ws", "status": scheme + host + "/status", "machine": host.get_slice(":", 0)}

## Ask only this server, over WebSockets, as a browser does (`urls` as from
## web_urls()). Tests use it outside a browser.
func watch_web(urls: Dictionary) -> void:
	_web = urls
	_web_retry = 0.0
	if _web_ws != null:
		_web_ws.close()
		_web_ws = null

## In a browser: keep a WebSocket open to the server's status port and ask it
## every few seconds. A closed one is reopened.
func _ask_web(delta: float) -> void:
	if _web_ws == null:
		_web_retry -= delta
		if _web_retry > 0.0:
			return
		_web_ws = WebSocketPeer.new()
		if _web_ws.connect_to_url(str(_web.status)) != OK:
			_web_ws = null
			_web_retry = ASK_EVERY
			return
		_ask_left = 0.0
	_web_ws.poll()
	match _web_ws.get_ready_state():
		WebSocketPeer.STATE_CLOSED:
			_web_ws = null
			_web_retry = ASK_EVERY
		WebSocketPeer.STATE_OPEN:
			_ask_left -= delta
			if _ask_left <= 0.0:
				_ask_left = ASK_EVERY
				_web_ws.send(query_packet())
			while _web_ws.get_available_packet_count() > 0:
				var packet := _web_ws.get_packet()
				var board := parse_board_reply(packet)
				if not board.is_empty():
					if _servers.has(str(_web.game)):
						board_found.emit(_servers[str(_web.game)], board)
					continue
				var reply := parse_reply(packet)
				if reply.is_empty():
					continue
				reply["machine"] = str(_web.machine)
				reply["address"] = str(_web.game)
				reply["seen"] = Time.get_ticks_msec() / 1000.0
				_servers[str(_web.game)] = reply
				found.emit(reply)
	var now := Time.get_ticks_msec() / 1000.0
	for key in _servers.keys():
		if now - float(_servers[key].seen) > FORGET_AFTER:
			_servers.erase(key)

# --- Tailscale ---------------------------------------------------------------

## Where the Tailscale command line lives on each kind of computer.
static func tailscale_paths() -> Array[String]:
	match OS.get_name():
		"macOS":
			return ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
		"Windows":
			var programs := OS.get_environment("ProgramFiles") if OS.has_environment("ProgramFiles") else "C:/Program Files"
			return [programs.path_join("Tailscale/tailscale.exe"), "C:/Program Files/Tailscale/tailscale.exe"]
	return ["/usr/bin/tailscale", "/usr/local/bin/tailscale", "/usr/sbin/tailscale", "/snap/bin/tailscale"]

## In the background thread: Tailscale's status, as {"json": text} or {"note": why not}.
func _read_tailscale() -> Dictionary:
	for path in tailscale_paths():
		if not FileAccess.file_exists(path):
			continue
		var out := []
		var code := OS.execute(path, ["status", "--json"], out, true)
		var text := str(out[0]) if not out.is_empty() else ""
		if text.strip_edges().begins_with("{"):
			return {"json": text}
		return {"note": "Tailscale didn't answer (is it switched on?)." if code != 0 else "Tailscale gave no list of machines."}
	return {"note": "notfound"}

## What to say when Tailscale isn't running here (`state` is its
## BackendState). "Stopped" is the app's switch turned off: the app can still
## be open, and a Mac can still list its Tailscale VPN as "connected", so say
## where the switch is.
static func tailscale_off_note(state: String) -> String:
	var where := "Tailscale's icon in the menu bar" if OS.get_name() == "macOS" \
		else "Tailscale's icon by the clock" if OS.get_name() == "Windows" else "`tailscale up`"
	if state == "Stopped":
		return "Tailscale is switched off on this computer, so it can't reach your tailnet. Switch it on (%s), then look again." % where
	return "Tailscale isn't connected on this computer (%s): it may need you to sign in. Open it (%s), then look again." % [state, where]

## The online machines in `tailscale status --json`, this one included, as
## {"peers": [{"name", "ip"}], "note": "" or why there are none}. Only their
## Tailscale IPv4 addresses (100.64.0.0/10) are used.
static func peers_from_status(text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		return {"peers": [], "note": "Couldn't read Tailscale's list of machines."}
	var state := str(data.get("BackendState", "Running"))
	if state != "Running":
		return {"peers": [], "note": tailscale_off_note(state)}
	var peers := []
	var nodes := []
	if data.get("Self") is Dictionary:
		nodes.append(data.Self)
	if data.get("Peer") is Dictionary:
		nodes.append_array(data.Peer.values())
	for node in nodes:
		if not node is Dictionary or not bool(node.get("Online", true)):
			continue
		var ip := ""
		var ips: Variant = node.get("TailscaleIPs", [])
		if ips is Array:
			for a in ips:
				if Net.is_tailscale(str(a)):
					ip = str(a)
					break
		if ip == "":
			continue
		var name := str(node.get("HostName", ""))
		var dns := str(node.get("DNSName", "")).get_slice(".", 0)
		if dns != "" and (name == "" or name == "localhost"):
			name = dns
		peers.append({"name": GameConfig.clean_name(name if name != "" else ip), "ip": ip})
	return {"peers": peers, "note": ""}

# --- the question and the answer ----------------------------------------------

## The question: QUERY_MAGIC, then this player's fingerprint (back_key()), so
## the answer can list their saved games there; then padding.
static func query_packet() -> PackedByteArray:
	var out := (QUERY_MAGIC + back_key(GameConfig.player_id())).to_ascii_buffer()
	out.resize(QUERY_SIZE)
	return out

## The same question, asking for the Hall of Fame instead of the status.
static func board_query_packet() -> PackedByteArray:
	var out := query_packet()
	out[14] = BOARD_ASK
	return out

static func is_board_query(packet: PackedByteArray) -> bool:
	return is_query(packet) and packet.size() > 14 and packet[14] == BOARD_ASK

## A Hall of Fame answer, cut to fit REPLY_LIMIT (bottom rows first).
static func make_board_reply(board: Dictionary) -> PackedByteArray:
	var copy := board.duplicate(true)
	var out := (BOARD_MAGIC + JSON.stringify(copy)).to_utf8_buffer()
	while out.size() > REPLY_LIMIT and copy.get("rows", []).size() > 0:
		copy.rows.pop_back()
		out = (BOARD_MAGIC + JSON.stringify(copy)).to_utf8_buffer()
	return out

## A Hall of Fame answer, checked, or {} if it isn't one.
static func parse_board_reply(packet: PackedByteArray) -> Dictionary:
	if packet.size() < 5 or packet.size() > 1400 or packet.slice(0, 4).get_string_from_ascii() != BOARD_MAGIC:
		return {}
	var data: Variant = JSON.parse_string(packet.slice(4).get_string_from_utf8())
	if not data is Dictionary:
		return {}
	var rows := []
	var raw: Variant = data.get("rows", [])
	if raw is Array:
		for r in raw.slice(0, 20):
			var row := _board_row(r)
			if not row.is_empty():
				rows.append(row)
	return {"rows": rows, "me": _board_row(data.get("me", [])), "players": maxi(0, _num(data.get("players"), rows.size()))}

static func _board_row(r: Variant) -> Array:
	if not r is Array or r.size() != 8:
		return []
	var out := [maxi(1, _num(r[0], 1)), GameConfig.clean_name(str(r[1])).left(16), str(r[2]).left(10)]
	for i in range(3, 8):
		out.append(maxi(0, _num(r[i], 0)))
	return out

## Asks `server` (an entry of servers()) for its Hall of Fame; the answer
## arrives as board_found.
func ask_board(server: Dictionary) -> void:
	if not _web.is_empty():
		if _web_ws != null and _web_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_web_ws.send(board_query_packet())
		return
	for ip in _servers:
		if str(_servers[ip].get("id", "")) == str(server.get("id", "")) and _targets.has(ip):
			var ws: WebSocketPeer = _tcp[ip].ws if _tcp.has(ip) else null
			if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				ws.send(board_query_packet())
				return
			_udp.set_dest_address(ip, int(_targets[ip].port) + STATUS_OFFSET)
			_udp.put_packet(board_query_packet())
			return

## The asker's fingerprint in a question, or "" (a copy from before 0.10).
static func query_key(packet: PackedByteArray) -> String:
	var key := packet.slice(4, 14).get_string_from_ascii()
	return key if key.length() == 10 and key.is_valid_hex_number() else ""

static func is_query(packet: PackedByteArray) -> bool:
	return packet.size() >= QUERY_SIZE and packet.slice(0, 4).get_string_from_ascii() == QUERY_MAGIC

## A server's answer: REPLY_MAGIC and then `info` as JSON, cut down to fit
## REPLY_LIMIT (the list of players goes first).
static func make_reply(info: Dictionary) -> PackedByteArray:
	var copy := info.duplicate(true)
	var out := (REPLY_MAGIC + JSON.stringify(copy)).to_utf8_buffer()
	while out.size() > REPLY_LIMIT and copy.get("players", []).size() > 0:
		copy.players.pop_back()
		out = (REPLY_MAGIC + JSON.stringify(copy)).to_utf8_buffer()
	if out.size() > REPLY_LIMIT:
		copy.erase("players")
		copy["name"] = str(copy.get("name", "")).left(20)
		copy["leader"] = str(copy.get("leader", "")).left(20)
		out = (REPLY_MAGIC + JSON.stringify(copy)).to_utf8_buffer()
	while out.size() > REPLY_LIMIT and copy.get("mine", []).size() > 0:
		copy.mine.pop_back()
		out = (REPLY_MAGIC + JSON.stringify(copy)).to_utf8_buffer()
	return out

## A server's answer, checked and tidied, or {} if it isn't one. Keys:
## v (version), p (protocol), id, name, port, state ("free", "setup" or
## "playing"), lobby ("players" or "always"), leader, crews, people (seats
## for players), taken, open, length, partner (2v2: the NAVS' partner, else
## -1), mine (the asker's saved games there: [{id, s}]),
## players (names), back (fingerprints of players who may come back into
## their crew, see back_key()), most (the most crews a game there may have) and defaults
## ({crews, size, length, difficulty}, for a new game there).
static func parse_reply(packet: PackedByteArray) -> Dictionary:
	if packet.size() < 5 or packet.size() > 1400 or packet.slice(0, 4).get_string_from_ascii() != REPLY_MAGIC:
		return {}
	var data: Variant = JSON.parse_string(packet.slice(4).get_string_from_utf8())
	if not data is Dictionary or str(data.get("game", "")) != "pirates-plunder":
		return {}
	var state := str(data.get("state", ""))
	if not state in ["free", "setup", "playing"]:
		return {}
	var players := []
	if data.get("players") is Array:
		for p in data.players.slice(0, 4):
			players.append(GameConfig.clean_name(str(p)))
	var defaults: Dictionary = data.get("defaults") if data.get("defaults") is Dictionary else {}
	var most := clampi(_num(data.get("most"), 2), GameConfig.MIN_TEAMS, GameConfig.MAX_TEAMS)
	return {
		"v": str(data.get("v", "?")).left(16),
		"p": _num(data.get("p"), 0),
		"id": str(data.get("id", "")).left(32),
		"name": GameConfig.clean_name(str(data.get("name", ""))),
		"port": clampi(_num(data.get("port"), Net.PORT), 1, 65534),
		"state": state,
		"lobby": "always" if str(data.get("lobby", "")) == "always" else "players",
		"leader": GameConfig.clean_name(str(data.get("leader", ""))),
		"crews": clampi(_num(data.get("crews"), 2), GameConfig.MIN_TEAMS, GameConfig.MAX_TEAMS),
		"people": clampi(_num(data.get("people"), 0), 0, GameConfig.MAX_TEAMS),
		"taken": clampi(_num(data.get("taken"), 0), 0, GameConfig.MAX_TEAMS),
		"open": clampi(_num(data.get("open"), 0), 0, GameConfig.MAX_TEAMS),
		"length": clampi(_num(data.get("length"), 1), 0, 2),
		"partner": _partner(data.get("partner")),
		"royale": _royale(data.get("royale")),
		"turn": _turn(data.get("turn")),
		"mine": _mine(data.get("mine")),
		"players": players,
		"back": _keys(data.get("back")),
		"most": most,
		"defaults": {
			"crews": clampi(_num(defaults.get("crews"), 2), GameConfig.MIN_TEAMS, most),
			"size": clampi(_num(defaults.get("size"), GameConfig.DEFAULT_TEAM_SIZE), 1, GameConfig.MAX_TEAM_SIZE),
			"length": clampi(_num(defaults.get("length"), 1), 0, 2),
			"difficulty": clampi(_num(defaults.get("difficulty"), 1), 0, 2),
			"partner": _partner(defaults.get("partner")),
			"turn": _turn(defaults.get("turn"), GameConfig.SERVER_TURN_SECONDS),
		},
	}

## A player's fingerprint in a server's "back" list: the crews whose players
## lost their connection and may come back into them.
static func back_key(player_id: String) -> String:
	return player_id.sha256_text().left(10)

## Whether that list says this copy's player may come back into their crew.
static func can_rejoin(s: Dictionary) -> bool:
	return str(s.get("state", "")) == "playing" and s.get("back", []).has(back_key(GameConfig.player_id()))

## The asker's saved games there, as the server listed them: [{id, s}].
static func _mine(v: Variant) -> Array:
	var out := []
	if v is Array:
		for g in v.slice(0, 3):
			if g is Dictionary and str(g.get("id", "")).length() <= 16 and str(g.get("id", "")) != "":
				out.append({"id": str(g.id), "s": _clean_line(str(g.get("s", ""))).left(60)})
	return out

static func _keys(v: Variant) -> Array:
	var out := []
	if v is Array:
		for k in v.slice(0, GameConfig.MAX_TEAMS):
			var key := str(k)
			if key.length() == 10 and key.is_valid_hex_number():
				out.append(key)
	return out

## 2v2: the NAVS' partner (1 to 3), else GameConfig.FREE_FOR_ALL.
## A turn limit in seconds (0: none), or `fallback` if it isn't one.
static func _turn(v: Variant, fallback := 0) -> int:
	return clampi(int(v), 0, 3600) if (v is int or v is float) else fallback

## A game's Battle Royale settings, or {} when it isn't one.
static func _royale(v: Variant) -> Dictionary:
	if not v is Dictionary or not bool(v.get("on", false)):
		return {}
	var rounds := int(v.get("rounds", 3)) if (v.get("rounds") is int or v.get("rounds") is float) else 3
	return {"on": true, "rounds": rounds if GameConfig.BR_ROUNDS.has(rounds) else 3, "vega": bool(v.get("vega", false))}

static func _partner(v: Variant) -> int:
	var p := _num(v, GameConfig.FREE_FOR_ALL)
	return p if p >= 1 and p < GameConfig.MAX_TEAMS else GameConfig.FREE_FOR_ALL

static func _num(v: Variant, fallback: int) -> int:
	return int(v) if v is int or v is float else fallback

## A line of text from a server, safe to show: printable, no BBCode, not too long.
static func _clean_line(raw: String) -> String:
	var out := ""
	for ch in raw.left(120):
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127 and not ch in ["[", "]"]:
			out += ch
	return out.strip_edges()
