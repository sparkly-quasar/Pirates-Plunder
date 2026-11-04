extends MultiplayerPeerExtension

## A host's connection that takes players two ways at once: copies of the game
## on a Mac or Windows over ENet (UDP), as always, and copies running in a web
## browser over WebSockets (TCP), which is all a browser can do. The rest of
## the game sees one ordinary connection with one set of player ids, so the
## rules, the lobby and the updater don't know or care how each player came.
##
## Each side hands out its own random ids (2 to 2^31 - 1). Should the two ever
## pick the same one, the newcomer is turned away and simply reconnects.
##
## WebSockets are always reliable and in order, so a browser player gets every
## message that way, whatever mode it was sent in.
##
## Not a class_name, like the server's own scripts: it works from a fresh
## checkout before Godot has rebuilt its class cache. Load it by path.

## Browsers get the island and every snapshot as single messages, so the
## buffer for what we send each of them is roomy; what they send us (clicks,
## chat, hello) is small.
const WEB_OUT_BUFFER := 1 << 22
const WEB_IN_BUFFER := 1 << 16
const HEARTBEAT := 10.0

var enet := ENetMultiplayerPeer.new()
var web: WebSocketMultiplayerPeer = null
var max_clients := 32

var _owner := {}          # peer id -> the inner peer it came through
var _gone: Array = []     # peers whose connection closed, told to the game at the next poll
var _queue: Array = []    # [peer, channel, mode, bytes], oldest first
var _target := 0
var _mode := TRANSFER_MODE_RELIABLE
var _channel := 0
var _refusing := false
var _open := false

## Listen for desktop copies on UDP `port`, and, unless `web_port` is
## negative, for browsers on TCP `web_port`. `bind` limits both to one
## address. Fails if either port can't be opened.
func listen(port: int, web_port: int, clients: int, bind := "") -> Error:
	max_clients = clients
	if bind != "":
		enet.set_bind_ip(bind)
	var err := enet.create_server(port, clients)
	if err != OK:
		return err
	enet.peer_connected.connect(_on_connected.bind(enet))
	enet.peer_disconnected.connect(_on_disconnected.bind(enet))
	if web_port >= 0:
		web = WebSocketMultiplayerPeer.new()
		web.outbound_buffer_size = WEB_OUT_BUFFER
		web.inbound_buffer_size = WEB_IN_BUFFER
		web.max_queued_packets = 4096
		err = web.create_server(web_port, bind if bind != "" else "*")
		if err != OK:
			enet.close()
			web = null
			return err
		web.peer_connected.connect(_on_connected.bind(web))
		web.peer_disconnected.connect(_on_disconnected.bind(web))
	_open = true
	return OK

## "a browser" or "the game", and the address it came from, for the log.
func describe(id: int) -> String:
	var inner: MultiplayerPeer = _owner.get(id)
	if inner == null:
		return ""
	if inner == web:
		return "a browser at %s" % web.get_peer_address(id)
	var p := enet.get_peer(id)
	return ("the game at %s" % p.get_remote_address()) if p != null else "the game"

func is_browser(id: int) -> bool:
	return web != null and _owner.get(id) == web

func _on_connected(id: int, inner: MultiplayerPeer) -> void:
	if _owner.has(id) or _owner.size() >= max_clients:
		inner.disconnect_peer(id, true) # the same id twice, or simply full
		return
	_owner[id] = inner
	if inner == web and web.get_peer(id) != null:
		# A phone that's switched off or out of signal never says goodbye.
		# Regular pings mean a dead connection fails (and its crew goes to the
		# computer) instead of lingering.
		web.get_peer(id).heartbeat_interval = HEARTBEAT
	peer_connected.emit(id)

## A connection closed. The game hears of it at the next poll, after it has
## read whatever that player sent last (a goodbye, say), which would otherwise
## be thrown away with them.
func _on_disconnected(id: int, inner: MultiplayerPeer) -> void:
	if _owner.get(id) == inner and not _gone.has(id): # not a newcomer we turned away
		_gone.append(id)

func _tell_gone() -> void:
	for id in _gone:
		_owner.erase(id)
		peer_disconnected.emit(id)
	_gone.clear()

# --- MultiplayerPeer --------------------------------------------------------------

func _poll() -> void:
	if not _open:
		return
	_tell_gone()
	_drain(enet)
	if web != null:
		_drain(web)

func _drain(inner: MultiplayerPeer) -> void:
	inner.poll()
	while inner.get_available_packet_count() > 0:
		var from := inner.get_packet_peer()
		var channel := inner.get_packet_channel()
		var mode := inner.get_packet_mode()
		var bytes := inner.get_packet()
		if _owner.get(from) == inner: # not from a newcomer we turned away
			_queue.append([from, channel, mode, bytes])

func _get_available_packet_count() -> int:
	return _queue.size()

func _get_packet_script() -> PackedByteArray:
	return _queue.pop_front()[3] if not _queue.is_empty() else PackedByteArray()

func _get_packet_peer() -> int:
	return int(_queue[0][0]) if not _queue.is_empty() else 0

func _get_packet_channel() -> int:
	return int(_queue[0][1]) if not _queue.is_empty() else 0

func _get_packet_mode() -> TransferMode:
	return _queue[0][2] if not _queue.is_empty() else TRANSFER_MODE_RELIABLE

func _put_packet_script(bytes: PackedByteArray) -> Error:
	if not _open:
		return ERR_UNCONFIGURED
	if _target > 0:
		var inner: MultiplayerPeer = _owner.get(_target)
		if inner == null:
			return ERR_INVALID_PARAMETER
		if _gone.has(_target):
			return OK # already gone; the game hears so at the next poll
		return _send(inner, _target, bytes)
	# Everyone (0), or everyone but one (-id): each side gets it, and the side
	# that one is on leaves them out.
	var result := OK
	for inner: MultiplayerPeer in _inners():
		if not _has_peers(inner):
			continue
		var t := _target if _target < 0 and _owner.get(-_target) == inner else 0
		var err := _send(inner, t, bytes)
		if err != OK:
			result = err
	return result

func _send(inner: MultiplayerPeer, target: int, bytes: PackedByteArray) -> Error:
	inner.set_target_peer(target)
	inner.transfer_mode = _mode
	inner.transfer_channel = _channel
	return inner.put_packet(bytes)

func _inners() -> Array:
	return [enet] if web == null else [enet, web]

func _has_peers(inner: MultiplayerPeer) -> bool:
	for id in _owner:
		if _owner[id] == inner:
			return true
	return false

func _set_target_peer(peer: int) -> void:
	_target = peer

func _set_transfer_mode(mode: TransferMode) -> void:
	_mode = mode

func _get_transfer_mode() -> TransferMode:
	return _mode

func _set_transfer_channel(channel: int) -> void:
	_channel = channel

func _get_transfer_channel() -> int:
	return _channel

func _get_max_packet_size() -> int:
	return 1 << 24

func _is_server() -> bool:
	return true

func _get_unique_id() -> int:
	return 1

func _is_server_relay_supported() -> bool:
	return false

func _get_connection_status() -> ConnectionStatus:
	return CONNECTION_CONNECTED if _open else CONNECTION_DISCONNECTED

func _set_refuse_new_connections(enable: bool) -> void:
	_refusing = enable
	for inner: MultiplayerPeer in _inners():
		inner.refuse_new_connections = enable

func _is_refusing_new_connections() -> bool:
	return _refusing

func _disconnect_peer(id: int, force: bool) -> void:
	var inner: MultiplayerPeer = _owner.get(id)
	if inner == null:
		return
	inner.disconnect_peer(id, force)
	if force:
		_on_disconnected(id, inner) # no goodbye to wait for
		_tell_gone()

func _close() -> void:
	if not _open:
		return
	_open = false
	for inner: MultiplayerPeer in _inners():
		inner.close()
	_owner.clear()
	_queue.clear()
	_gone.clear()
