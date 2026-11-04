extends Node

## Hands out the game for web browsers: the Web export (tools/package.sh puts
## it in web/ beside the server), over plain HTTP on its own TCP port. Open
## http://<server's address>:<port>/ on a phone (with Tailscale, the server's
## 100.x address) and the game loads, already pointed at this server: the
## page at / sends the browser on to index.html?server=<that address>:<game
## port>.
##
## Small on purpose: GET and HEAD for the files in that one folder, nothing
## else. A file ending .gz beside one (index.wasm.gz) is sent instead to a
## browser that takes gzip, which is most of the download saved. Big files go
## out a slice at a time, so a phone loading the game doesn't stall a game in
## progress. A browser that already has a file is told so (ETag).
##
## Not a class_name, like the server's own scripts. Load it by path.

const MAX_CONNECTIONS := 24
const MAX_REQUEST := 8192
const QUIET_SECONDS := 30.0
const SLICE := 1 << 20 # bytes sent to each browser per frame, at most

const TYPES := {
	"html": "text/html; charset=utf-8", "js": "text/javascript", "wasm": "application/wasm",
	"pck": "application/octet-stream", "png": "image/png", "json": "application/json",
	"svg": "image/svg+xml", "ico": "image/x-icon", "txt": "text/plain; charset=utf-8",
	"webmanifest": "application/manifest+json",
}

var folder := ""
var game_port := 24680
var tag := ""                   # goes into each ETag: the game's version

var _tcp := TCPServer.new()
var _conns: Array = []          # {peer, got (request bytes), file, left, last}

func listen(port: int, bind := "") -> Error:
	return _tcp.listen(port, bind if bind != "" else "*")

## Whether there's a game here to hand out.
static func has_game(path: String) -> bool:
	return path != "" and FileAccess.file_exists(path.path_join("index.html"))

func _exit_tree() -> void:
	for c in _conns:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_tcp.stop()

func _process(_delta: float) -> void:
	if not _tcp.is_listening():
		return
	var now := Time.get_ticks_msec() / 1000.0
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		if _conns.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
			continue
		_conns.append({"peer": peer, "got": PackedByteArray(), "file": null, "left": 0, "last": now})
	for c in _conns.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		var state := peer.get_status()
		if state == StreamPeerTCP.STATUS_ERROR or state == StreamPeerTCP.STATUS_NONE or now - float(c.last) > QUIET_SECONDS:
			_close(c)
			continue
		if state != StreamPeerTCP.STATUS_CONNECTED:
			continue
		if c.file != null:
			_send_more(c, now)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var part: Array = peer.get_partial_data(mini(n, MAX_REQUEST))
			if part[0] == OK:
				c.got.append_array(part[1])
				c.last = now
		var text: String = (c.got as PackedByteArray).get_string_from_ascii()
		if text.contains("\r\n\r\n"):
			_answer(c, text)
		elif (c.got as PackedByteArray).size() >= MAX_REQUEST:
			_reply(c, 431, "Request Header Fields Too Large", "text/plain", "Too big.".to_utf8_buffer())

func _answer(c: Dictionary, request: String) -> void:
	var lines := request.split("\r\n")
	var first := lines[0].split(" ")
	var headers := {}
	for line in lines.slice(1):
		var colon := line.find(":")
		if colon > 0:
			headers[line.left(colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	if first.size() < 2 or not first[0] in ["GET", "HEAD"]:
		_reply(c, 405, "Method Not Allowed", "text/plain", "GET only.".to_utf8_buffer())
		return
	var head: bool = first[0] == "HEAD"
	var path := first[1].get_slice("?", 0).uri_decode()
	if path == "/" or path == "":
		# On to the game, pointed at this server by the name the browser used.
		var host := str(headers.get("host", "")).get_slice(":", 0)
		if host.begins_with("["): # an IPv6 address
			host = str(headers.get("host", "")).get_slice("]", 0) + "]"
		var to := "/index.html?server=%s:%d" % [host.uri_encode(), game_port]
		_reply(c, 302, "Found", "text/plain", PackedByteArray(), {"Location": to})
		return
	var name := path.trim_prefix("/")
	if name.contains("..") or name.contains("/") or name.contains("\\") or name.begins_with("."):
		_reply(c, 404, "Not Found", "text/plain", "Not here.".to_utf8_buffer())
		return
	var file_path := folder.path_join(name)
	if not FileAccess.file_exists(file_path):
		_reply(c, 404, "Not Found", "text/plain", "Not here.".to_utf8_buffer())
		return
	var extra := {"Cache-Control": "no-cache"}
	var send_path := file_path
	if str(headers.get("accept-encoding", "")).contains("gzip") and FileAccess.file_exists(file_path + ".gz"):
		send_path = file_path + ".gz"
		extra["Content-Encoding"] = "gzip"
		extra["Vary"] = "Accept-Encoding"
	var f := FileAccess.open(send_path, FileAccess.READ)
	if f == null:
		_reply(c, 404, "Not Found", "text/plain", "Not here.".to_utf8_buffer())
		return
	var etag := "\"%s-%d-%d\"" % [tag, f.get_length(), FileAccess.get_modified_time(send_path)]
	extra["ETag"] = etag
	if str(headers.get("if-none-match", "")) == etag:
		_reply(c, 304, "Not Modified", "", PackedByteArray(), extra)
		return
	var type: String = TYPES.get(name.get_extension().to_lower(), "application/octet-stream")
	_head(c, 200, "OK", type, f.get_length(), extra)
	if head:
		_close(c)
		return
	c.file = f
	c.left = f.get_length()

func _send_more(c: Dictionary, now: float) -> void:
	var peer: StreamPeerTCP = c.peer
	var f: FileAccess = c.file
	var budget := SLICE
	while budget > 0 and int(c.left) > 0:
		var chunk := f.get_buffer(mini(mini(budget, 65536), int(c.left)))
		var sent: Array = peer.put_partial_data(chunk)
		if sent[0] != OK:
			_close(c)
			return
		var n := int(sent[1])
		if n < chunk.size():
			f.seek(f.get_position() - (chunk.size() - n)) # the rest goes next frame
		c.left = int(c.left) - n
		budget -= n
		if n == 0:
			break
		c.last = now
	if int(c.left) <= 0:
		_close(c)

func _head(c: Dictionary, code: int, why: String, type: String, length: int, extra := {}) -> void:
	var text := "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n" % [code, why, length]
	if type != "":
		text += "Content-Type: %s\r\n" % type
	for k in extra:
		text += "%s: %s\r\n" % [k, extra[k]]
	(c.peer as StreamPeerTCP).put_data((text + "\r\n").to_utf8_buffer())

func _reply(c: Dictionary, code: int, why: String, type: String, body: PackedByteArray, extra := {}) -> void:
	_head(c, code, why, type, body.size(), extra)
	if body.size() > 0:
		(c.peer as StreamPeerTCP).put_data(body)
	_close(c)

func _close(c: Dictionary) -> void:
	if c.file != null:
		(c.file as FileAccess).close()
		c.file = null
	(c.peer as StreamPeerTCP).disconnect_from_host()
	_conns.erase(c)
