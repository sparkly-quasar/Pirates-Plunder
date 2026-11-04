extends Node

## Answers server-list questions from copies of the game running in a web
## browser. A browser can't send the small UDP question the desktop game uses
## (see ServerFinder), so it opens a WebSocket to this TCP port instead and
## asks the same question over it, every few seconds while its list is open.
## The answer is the same as over UDP.
##
## Kept small and wary, since anyone who can reach the port can open one: a
## few dozen connections at most, a handful of questions a second each, and a
## connection that goes quiet is closed.
##
## Not a class_name, like the server's own scripts. Load it by path.

const MAX_CONNECTIONS := 32
const QUIET_SECONDS := 30.0
const PER_SECOND := 3

## Returns the Dictionary to answer with (the server's status), given the
## asker's fingerprint (ServerFinder.query_key()), which may be "".
var info := Callable()
## Returns the Hall of Fame for an asker's fingerprint (a Hall of Fame query).
var board := Callable()

var _tcp := TCPServer.new()
var _conns: Array = [] # {ws, last (seconds), second, asked}

func listen(port: int, bind := "") -> Error:
	return _tcp.listen(port, bind if bind != "" else "*")

func _exit_tree() -> void:
	for c in _conns:
		(c.ws as WebSocketPeer).close()
	_tcp.stop()

func _process(_delta: float) -> void:
	if not _tcp.is_listening():
		return
	var now := Time.get_ticks_msec() / 1000.0
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		if _conns.size() >= MAX_CONNECTIONS:
			stream.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 4096
		ws.outbound_buffer_size = 4096
		ws.max_queued_packets = 8
		if ws.accept_stream(stream) == OK:
			_conns.append({"ws": ws, "last": now, "second": 0, "asked": 0})
	for c in _conns.duplicate():
		var ws: WebSocketPeer = c.ws
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_conns.erase(c)
			continue
		if now - float(c.last) > QUIET_SECONDS:
			ws.close()
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		while ws.get_available_packet_count() > 0:
			var packet := ws.get_packet()
			if not ServerFinder.is_query(packet) or packet.size() > ServerFinder.QUERY_SIZE:
				continue
			c.last = now
			var second := floori(now)
			if int(c.second) != second:
				c.second = second
				c.asked = 0
			c.asked = int(c.asked) + 1
			if int(c.asked) <= PER_SECOND and ServerFinder.is_board_query(packet) and board.is_valid():
				ws.send(ServerFinder.make_board_reply(board.call(ServerFinder.query_key(packet))))
			elif int(c.asked) <= PER_SECOND and info.is_valid():
				ws.send(ServerFinder.make_reply(info.call(ServerFinder.query_key(packet))))
