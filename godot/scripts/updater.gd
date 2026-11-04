class_name Updater
extends Node

## Hands the game itself to a friend who has a different version, so nobody
## has to go looking for the right download before they can play together.
##
## When two copies connect, each says hello: its version, what computer it runs
## on, and which versions of the game it can hand over. Same version: on with
## the game. Different: the OLDER copy is offered the newer one, downloads it
## from the friend over the same connection, checks every byte against the
## friend's fingerprint (SHA-256), installs it in place of itself and restarts
## (a guest rejoins the same address on its own).
##
## Every download carries both versions of the game: the Mac app has the
## Windows exe inside, and the Windows exe has the Mac app (zipped) inside. So a
## Mac can serve a Windows friend and the other way round. A Mac serves Macs by
## zipping its own app; a Windows copy serves Windows by sending its own exe.
##
## This talks in raw packets rather than RPCs, and its messages must never
## change shape: it has to understand copies older and newer than itself. Old
## copies (before 0.6.1) don't say hello at all; Net falls back to the old
## handshake for them.

signal versions_match(peer: int)
## They have a different version. `newer` is true when theirs is the newer
## one (so we're the one who'd download); `can_get` says whether their copy can
## hand over a version for this computer.
signal versions_differ(peer: int, version: String, newer: bool, can_get: bool)
signal download_progress(done: int, total: int)
signal download_failed(reason: String)
signal installing(message: String)
## A friend is downloading from us.
signal serving_progress(peer: int, done: int, total: int)
## The other side sent us away, and said why (a full game, a timeout...).
signal refused(peer: int, reason: String)

const MAGIC := "PPUP"
const CHUNK := 60000
const IN_FLIGHT := 8
const MAC_ZIP := "PiratesPlunder-mac.zip"
const WIN_EXE := "PiratesPlunder-windows.exe"
## Where the builds tuck the other computer's version (see tools/package.sh).
const BUNDLED_MAC := "res://dist/mac/" + MAC_ZIP
const BUNDLED_WIN := "res://dist/windows/" + WIN_EXE
const WORK_DIR := "user://update"
const SHARE_DIR := "user://share"

## Tests: serve these files instead of the real game ({os: [paths]}), and stop
## once downloaded instead of installing.
var test_files := {}
var dry_run := false
## Tests: behave like a copy from before 0.6.1, which never says hello.
var silent := false
## Where to rejoin after restarting (a guest's host address), if anywhere.
var rejoin_address := ""
## More arguments for the restart (the server list asks to come back to it).
var relaunch_extra := PackedStringArray()
## A dedicated server hands out the release downloads from this folder
## instead of its own copy, which is neither a Mac app nor a Windows exe:
## <serve_dir>/<version>/PiratesPlunder-mac.zip and PiratesPlunder-windows.exe,
## named by version so a server can never hand out the wrong one.
var serve_dir := ""
## The version being downloaded.
var incoming_version := ""

var _hellos := {}            # peer -> their hello
var _prepared := {}          # os -> [{name, size, sha, src}]
var _waiting := {}           # os -> peers waiting for it to be prepared
var _thread: Thread = null
var _thread_os := ""
var _readers := {}           # src -> FileAccess
var _peer_os := {}           # peer -> the computer they asked for a version for
var _served := {}            # peer -> bytes sent

# The download in progress, if any.
var _dl_peer := 0
var _dl_files: Array = []
var _req_f := 0
var _req_at := 0
var _w_f := 0
var _w_at := 0
var _w_file: FileAccess = null
var _w_hash: HashingContext = null
var _done_bytes := 0
var _total_bytes := 0

static func platform() -> String:
	return OS.get_name()

## -1, 0 or 1 as version `a` is older than, the same as, or newer than `b`.
static func compare(a: String, b: String) -> int:
	var x := a.split(".")
	var y := b.split(".")
	for i in maxi(x.size(), y.size()):
		var p := int(x[i]) if i < x.size() else 0
		var q := int(y[i]) if i < y.size() else 0
		if p != q:
			return -1 if p < q else 1
	return 0

func _ready() -> void:
	# Tidy up after an update on Windows, which can't delete a running exe.
	if platform() == "Windows" and OS.has_feature("template"):
		var old := OS.get_executable_path() + ".old"
		if FileAccess.file_exists(old):
			DirAccess.remove_absolute(old)

func reset() -> void:
	_hellos.clear()
	_served.clear()
	_peer_os.clear()
	_close_readers()
	if _dl_peer != 0:
		_abort_download("")

func knows(peer: int) -> bool:
	return _hellos.has(peer)

func is_downloading() -> bool:
	return _dl_peer != 0

# --- hello -------------------------------------------------------------------

func greet(peer: int) -> void:
	if silent:
		return
	var hello := {"t": "hello", "v": GameConfig.version(), "p": Net.PROTOCOL, "os": platform(), "serve": _can_serve(),
		"dedicated": Net.is_dedicated_host(), "player": GameConfig.player_id(), "name": GameConfig.player_name(),
		"captain": GameConfig.is_captain()}
	if Net.role == Net.Role.GUEST and Net.server_request != null:
		hello["start"] = Net.server_request # to a server: start a game there (see Net.server_request)
	_send(peer, hello)

## The random id their copy keeps (GameConfig.player_id()), or "".
func player_of(peer: int) -> String:
	return str(_hellos.get(peer, {}).get("player", "")).left(64)

## The name they go by (GameConfig.player_name()), or "" from a copy before 0.8.0.
func name_of(peer: int) -> String:
	return GameConfig.clean_name(str(_hellos.get(peer, {}).get("name", "")))

## They've finished the campaign: their ship flies the Golden Rooster flag.
func is_captain(peer: int) -> bool:
	return bool(_hellos.get(peer, {}).get("captain", false))

## What they asked a server for when they connected (Net.server_request), or null.
func request_of(peer: int) -> Variant:
	return _hellos.get(peer, {}).get("start")

## Their hello said they're a dedicated server.
func is_dedicated(peer: int) -> bool:
	return bool(_hellos.get(peer, {}).get("dedicated", false))

## We can hand `peer` a version of the game for their computer.
func can_serve_to(peer: int) -> bool:
	return _can_serve().has(str(_hellos.get(peer, {}).get("os", "")))

## Tell `peer` why they're being sent away. (A new kind of message: copies
## that don't know it ignore it, so this doesn't change any message's shape.)
func say_goodbye(peer: int, reason: String) -> void:
	_send(peer, {"t": "bye", "why": reason})

## Which computers' versions this copy can hand over.
func _can_serve() -> Array:
	var out := []
	for os_name in ["macOS", "Windows"]:
		if test_files.has(os_name) or not _sources(os_name).is_empty():
			out.append(os_name)
	# The version tests serve stand-in files for the computer they run on,
	# which can be Linux (a cloud machine), not only a Mac or Windows.
	for os_name in test_files:
		if not out.has(os_name):
			out.append(os_name)
	return out

func peer_gone(peer: int) -> void:
	_hellos.erase(peer)
	_served.erase(peer)
	_peer_os.erase(peer)
	if peer == _dl_peer:
		_abort_download("Lost the connection to your friend partway through the download.")

func on_packet(peer: int, packet: PackedByteArray) -> void:
	if silent:
		return
	if packet.size() < 4 or packet.slice(0, 4).get_string_from_ascii() != MAGIC:
		return
	var msg: Variant = bytes_to_var(packet.slice(4))
	if not msg is Dictionary:
		return
	match str(msg.get("t", "")):
		"hello": _on_hello(peer, msg)
		"want": _on_want(peer, str(msg.get("os", "")))
		"files": _on_files(peer, msg.get("files", []))
		"nope": if peer == _dl_peer: _abort_download(str(msg.get("why", "Your friend's copy couldn't send it.")))
		"get": _on_get(peer, int(msg.get("f", 0)), int(msg.get("at", 0)), int(msg.get("n", 0)))
		"chunk": _on_chunk(peer, int(msg.get("f", -1)), int(msg.get("at", -1)), msg.get("data", PackedByteArray()))
		"bye": refused.emit(peer, str(msg.get("why", "")).left(300))

func _on_hello(peer: int, msg: Dictionary) -> void:
	_hellos[peer] = msg
	var theirs := str(msg.get("v", ""))
	var order := compare(theirs, GameConfig.version())
	if order == 0:
		versions_match.emit(peer)
		return
	var serve: Array = msg.get("serve", [])
	versions_differ.emit(peer, theirs, order > 0, serve.has(platform()))

# --- downloading -------------------------------------------------------------

## Ask `peer` for their version of the game for this computer.
func download_from(peer: int) -> void:
	if _dl_peer != 0:
		return
	_dl_peer = peer
	_dl_files = []
	incoming_version = str(_hellos.get(peer, {}).get("v", ""))
	_send(peer, {"t": "want", "os": platform()})

func _on_files(peer: int, files: Array) -> void:
	if peer != _dl_peer or files.is_empty():
		return
	_dl_files = files
	_total_bytes = 0
	for f in files:
		_total_bytes += int(f.size)
	_done_bytes = 0
	DirAccess.make_dir_recursive_absolute(WORK_DIR)
	_req_f = 0
	_req_at = 0
	_w_f = 0
	_w_at = 0
	if not _open_part(0):
		return
	download_progress.emit(0, _total_bytes)
	for i in IN_FLIGHT:
		_request_next()

func _open_part(i: int) -> bool:
	_w_file = FileAccess.open(_part_path(i), FileAccess.WRITE)
	if _w_file == null:
		_abort_download("Couldn't save the download (no room on the disk?).")
		return false
	_w_hash = HashingContext.new()
	_w_hash.start(HashingContext.HASH_SHA256)
	return true

func _part_path(i: int) -> String:
	return WORK_DIR.path_join(str(_dl_files[i].name).get_file() + ".part")

func _request_next() -> void:
	if _req_f >= _dl_files.size():
		return
	var size := int(_dl_files[_req_f].size)
	var n := mini(CHUNK, size - _req_at)
	_send(_dl_peer, {"t": "get", "f": _req_f, "at": _req_at, "n": n})
	_req_at += n
	if _req_at >= size:
		_req_f += 1
		_req_at = 0

func _on_chunk(peer: int, f: int, at: int, data: PackedByteArray) -> void:
	if peer != _dl_peer or f != _w_f or at != _w_at or data.is_empty():
		return
	_w_file.store_buffer(data)
	_w_hash.update(data)
	_w_at += data.size()
	_done_bytes += data.size()
	download_progress.emit(_done_bytes, _total_bytes)
	if _w_at >= int(_dl_files[f].size):
		_w_file.close()
		var sha := _w_hash.finish().hex_encode()
		if sha != str(_dl_files[f].sha):
			_abort_download("The download came through damaged. Try again.")
			return
		var final := WORK_DIR.path_join(str(_dl_files[f].name).get_file())
		DirAccess.remove_absolute(final)
		DirAccess.rename_absolute(_part_path(f), final)
		_w_f += 1
		_w_at = 0
		if _w_f >= _dl_files.size():
			_finish_download()
			return
		if not _open_part(_w_f):
			return
	_request_next()

func _abort_download(reason: String) -> void:
	if _w_file != null:
		_w_file.close()
	_w_file = null
	_dl_peer = 0
	_dl_files = []
	if reason != "":
		download_failed.emit(reason)

func _finish_download() -> void:
	var names := []
	for f in _dl_files:
		names.append(str(f.name).get_file())
	_dl_peer = 0
	if dry_run:
		installing.emit("Downloaded.")
		return
	_install(names)

## Installs files downloaded some other way (from the public releases:
## ReleaseUpdate) into WORK_DIR, as version `version`.
func install_files(names: Array, version: String) -> void:
	incoming_version = version
	_install(names)

# --- serving -----------------------------------------------------------------

func _on_want(peer: int, os_name: String) -> void:
	_peer_os[peer] = os_name
	if _prepared.has(os_name):
		_send(peer, {"t": "files", "files": _public(_prepared[os_name])})
		return
	if not _waiting.has(os_name):
		_waiting[os_name] = []
	_waiting[os_name].append(peer)
	if _thread == null:
		_start_preparing(os_name)

func _start_preparing(os_name: String) -> void:
	_thread_os = os_name
	_thread = Thread.new()
	_thread.start(_prepare.bind(os_name))

## Runs on a thread: zips this Mac's app if needed, and fingerprints each file.
func _prepare(os_name: String) -> Array:
	var out := []
	var srcs: Array = _sources(os_name)
	if test_files.has(os_name):
		srcs = test_files[os_name].map(func(p: String) -> Array: return [p, p.get_file()])
	for src in srcs:
		var path := str(src[0])
		if path == "self-zip":
			path = _zip_self()
			if path == "":
				return []
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return []
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		while f.get_position() < f.get_length():
			h.update(f.get_buffer(1 << 20))
		out.append({"name": str(src[1]), "size": f.get_length(), "sha": h.finish().hex_encode(), "src": path})
	return out

func _process(_delta: float) -> void:
	if _thread == null or _thread.is_alive():
		return
	var files: Array = _thread.wait_to_finish()
	_thread = null
	var os_name := _thread_os
	var peers: Array = _waiting.get(os_name, [])
	_waiting.erase(os_name)
	if files.is_empty():
		for p in peers:
			_send(p, {"t": "nope", "why": "Your friend's copy couldn't get the %s version ready." % os_name})
	else:
		_prepared[os_name] = files
		for p in peers:
			_send(p, {"t": "files", "files": _public(files)})
	if not _waiting.is_empty():
		_start_preparing(str(_waiting.keys()[0]))

func _public(files: Array) -> Array:
	return files.map(func(f: Dictionary) -> Dictionary: return {"name": f.name, "size": f.size, "sha": f.sha})

func _on_get(peer: int, f: int, at: int, n: int) -> void:
	var files: Array = _prepared.get(_peer_os.get(peer, ""), [])
	if f < 0 or f >= files.size() or n <= 0 or n > CHUNK:
		return
	var src := str(files[f].src)
	if not _readers.has(src):
		_readers[src] = FileAccess.open(src, FileAccess.READ)
	var r: FileAccess = _readers[src]
	if r == null:
		return
	r.seek(at)
	_send(peer, {"t": "chunk", "f": f, "at": at, "data": r.get_buffer(n)})
	_served[peer] = int(_served.get(peer, 0)) + n
	var total := 0
	for x in files:
		total += int(x.size)
	serving_progress.emit(peer, int(_served[peer]), total)

func _close_readers() -> void:
	_readers.clear()

## The files a friend on `os_name` needs, as [path, name to send it as]
## ("self-zip" = zip this Mac's own app first). Empty when this copy can't
## provide that version.
func _sources(os_name: String) -> Array:
	if serve_dir != "":
		return _served_downloads(os_name)
	var exported := OS.has_feature("template")
	var mac := []
	if platform() == "macOS" and exported and _own_bundle() != "":
		mac = ["self-zip", MAC_ZIP]
	elif FileAccess.file_exists(BUNDLED_MAC):
		mac = [BUNDLED_MAC, MAC_ZIP]
	elif FileAccess.file_exists(_shared_mac()):
		mac = [_shared_mac(), MAC_ZIP]
	var out := []
	if os_name == "macOS":
		if not mac.is_empty():
			out.append(mac)
	elif os_name == "Windows":
		if platform() == "Windows" and exported:
			# Our own exe. One from the release has the Mac app inside already.
			out.append([OS.get_executable_path(), WIN_EXE])
			if not FileAccess.file_exists(BUNDLED_MAC) and not mac.is_empty():
				out.append(mac)
		elif FileAccess.file_exists(BUNDLED_WIN):
			out.append([BUNDLED_WIN, WIN_EXE])
			if not mac.is_empty():
				out.append(mac)
	return out

## A dedicated server's downloads for `os_name`, if the operator put them in
## place. The release exe already has the Mac app inside it.
func _served_downloads(os_name: String) -> Array:
	var dir := serve_dir.path_join(GameConfig.version())
	var file := MAC_ZIP if os_name == "macOS" else (WIN_EXE if os_name == "Windows" else "")
	if file == "" or not FileAccess.file_exists(dir.path_join(file)):
		return []
	return [[dir.path_join(file), file]]

## A Windows copy that came from a Mac keeps the Mac app it was sent alongside,
## so it can pass it on in turn.
func _shared_mac() -> String:
	return SHARE_DIR.path_join("PiratesPlunder-mac-%s.zip" % GameConfig.version())

## This Mac's own .app folder, or "" when not running from one.
func _own_bundle() -> String:
	var exe := OS.get_executable_path()
	if not exe.contains(".app/Contents/MacOS/"):
		return ""
	return exe.get_base_dir().get_base_dir().get_base_dir()

## Zips this Mac's app (once per version) for a friend. Runs on the thread.
func _zip_self() -> String:
	DirAccess.make_dir_recursive_absolute(SHARE_DIR)
	var zip := ProjectSettings.globalize_path(SHARE_DIR.path_join("self-%s.zip" % GameConfig.version()))
	if FileAccess.file_exists(zip):
		return zip
	var tmp := zip + ".tmp"
	DirAccess.remove_absolute(tmp)
	if OS.execute("/usr/bin/ditto", ["-c", "-k", "--keepParent", _own_bundle(), tmp]) != 0:
		return ""
	DirAccess.rename_absolute(tmp, zip)
	return zip

# --- installing --------------------------------------------------------------

func _install(names: Array) -> void:
	var work := ProjectSettings.globalize_path(WORK_DIR)
	if platform() == "macOS" and names.has(MAC_ZIP):
		_install_mac(work.path_join(MAC_ZIP))
	elif platform() == "Windows" and names.has(WIN_EXE):
		if names.has(MAC_ZIP):
			DirAccess.make_dir_recursive_absolute(SHARE_DIR)
			_clear_shared()
			DirAccess.rename_absolute(work.path_join(MAC_ZIP), ProjectSettings.globalize_path(_shared_mac_for_new()))
		_install_windows(work.path_join(WIN_EXE))
	else:
		download_failed.emit("That download is for a different computer.")

## The Mac app arriving with a new Windows exe is that new version, so it's
## filed under the version we're about to become.
func _shared_mac_for_new() -> String:
	return SHARE_DIR.path_join("PiratesPlunder-mac-%s.zip" % incoming_version)

func _clear_shared() -> void:
	for f in DirAccess.get_files_at(SHARE_DIR):
		if f.begins_with("PiratesPlunder-mac-"):
			DirAccess.remove_absolute(SHARE_DIR.path_join(f))

func _relaunch_args() -> PackedStringArray:
	var args := PackedStringArray(["--", "--updated"])
	if rejoin_address != "":
		args.append("--join=" + rejoin_address)
	args.append_array(relaunch_extra)
	return args

func _install_mac(zip: String) -> void:
	var unpack := ProjectSettings.globalize_path(WORK_DIR.path_join("unpacked-%d" % Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(unpack)
	if OS.execute("/usr/bin/ditto", ["-x", "-k", zip, unpack]) != 0:
		download_failed.emit("Couldn't unpack the new version.")
		return
	var app := ""
	for d in DirAccess.get_directories_at(unpack):
		if d.ends_with(".app"):
			app = unpack.path_join(d)
	if app == "":
		download_failed.emit("The download didn't contain the game.")
		return
	var own := _own_bundle()
	if own == "" or not _writable(own.get_base_dir()) or own.begins_with("/Volumes/"):
		# Not running from an app we can replace (say, straight off the disk
		# image): leave the new one in Downloads and show it.
		var dest := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS).path_join("Pirates Plunder %s.app" % incoming_version)
		if DirAccess.dir_exists_absolute(dest):
			OS.move_to_trash(dest)
		DirAccess.rename_absolute(app, dest)
		OS.execute("/usr/bin/open", ["-R", dest])
		installing.emit("The new version is in your Downloads folder. Drag it into Applications, then open it.")
		return
	# A little script swaps the apps once this one has quit, then opens it.
	var script := unpack.path_join("swap.sh")
	var f := FileAccess.open(script, FileAccess.WRITE)
	var args := " ".join(Array(_relaunch_args()).map(func(a: String) -> String: return "'%s'" % a))
	f.store_string("#!/bin/sh\nwhile kill -0 %d 2>/dev/null; do sleep 0.2; done\nrm -rf '%s' && mv '%s' '%s' && open '%s' --args %s\n" % [
		OS.get_process_id(), own, app, own, own, args])
	f.close()
	installing.emit("Installing the new version. The game will restart in a moment...")
	OS.create_process("/bin/sh", [script])
	get_tree().create_timer(1.0).timeout.connect(get_tree().quit)

func _install_windows(exe: String) -> void:
	var own := OS.get_executable_path()
	if not OS.has_feature("template") or not _windows_swap(own, exe):
		var dest := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS).path_join("PiratesPlunder-%s.exe" % incoming_version)
		DirAccess.remove_absolute(dest)
		if DirAccess.copy_absolute(exe, dest) != OK:
			download_failed.emit("Couldn't save the new version.")
			return
		DirAccess.remove_absolute(exe)
		OS.shell_show_in_file_manager(dest)
		installing.emit("The new version is in your Downloads folder. Run it from there.")
		return
	installing.emit("Installing the new version. The game will restart in a moment...")
	OS.create_process(own, _relaunch_args())
	get_tree().create_timer(0.5).timeout.connect(get_tree().quit)

## Windows lets a running exe be renamed but not overwritten: move ours aside,
## put the new one in its place. Puts ours back if anything fails.
func _windows_swap(own: String, exe: String) -> bool:
	var old := own + ".old"
	if FileAccess.file_exists(old) and DirAccess.remove_absolute(old) != OK:
		return false
	if DirAccess.rename_absolute(own, old) != OK:
		return false
	if DirAccess.copy_absolute(exe, own) != OK:
		DirAccess.rename_absolute(old, own)
		return false
	DirAccess.remove_absolute(exe)
	return true

func _writable(dir: String) -> bool:
	var probe := dir.path_join(".pp-write-test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true

# --- wire ----------------------------------------------------------------------

func _send(peer: int, msg: Dictionary) -> void:
	var mp := multiplayer as SceneMultiplayer
	if mp == null or mp.multiplayer_peer == null:
		return
	var bytes := MAGIC.to_ascii_buffer()
	bytes.append_array(var_to_bytes(msg))
	mp.send_bytes(bytes, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
