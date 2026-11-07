extends RefCounted

## A dedicated server's saved games, each belonging to the players who played
## it (by the player id their copy keeps: GameConfig.player_id()). A player
## sees their own in the server list and can continue one when the server is
## free; the others in it come back into their own crews.
##
## One file per game in the saves folder, <id>.cfg, written by
## GameConfig.save_game() plus a [server] section: when it was saved, the
## players' names, and which players lost their connection (rather than
## leaving on purpose), so a copy that reconnects by itself can be put
## straight back into its game.
##
## Kept small: each player keeps their KEEP_EACH most recent saved games (a
## game shared with someone who still wants it stays), and none lasts longer
## than `days`.
##
## Not a class_name, like the server's own scripts. Load it by path.

const KEEP_EACH := 3
const LIST_MAX := 3          # saved games one player's list shows
const SUMMARY_MAX := 60

var folder := ""
var days := 30.0
var _games := {}             # id -> {owners: Array[String], keys, names, summary, at, dropped}

func open(path: String, keep_days: float) -> Error:
	folder = path
	days = keep_days
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if err != OK and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		return err
	# The folder existing isn't enough: a Docker volume owned by root, say,
	# is there but every save would fail. Write a file to be sure.
	var probe := ProjectSettings.globalize_path(folder.path_join(".write-test"))
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return ERR_FILE_CANT_WRITE
	f.close()
	DirAccess.remove_absolute(probe)
	_scan()
	prune()
	return OK

func enabled() -> bool:
	return folder != ""

func count() -> int:
	return _games.size()

static func new_id() -> String:
	return Crypto.new().generate_random_bytes(4).hex_encode()

static func valid_id(id: String) -> bool:
	if id.length() < 1 or id.length() > 16:
		return false
	for ch in id:
		if not (ch >= "a" and ch <= "z") and not (ch >= "0" and ch <= "9") and ch != "-":
			return false
	return true

func path_of(id: String) -> String:
	return folder.path_join(id + ".cfg")

func has(id: String) -> bool:
	return _games.has(id)

## Whether this player was in that saved game.
func owns(id: String, player: String) -> bool:
	return player != "" and _games.has(id) and _games[id].owners.has(player)

## Their saved games, newest first: [{id, s (a line saying what it is)}].
func mine(key: String) -> Array:
	var out := []
	if key == "":
		return out
	for id in _newest():
		if _games[id].keys.has(key):
			out.append({"id": id, "s": str(_games[id].summary)})
			if out.size() >= LIST_MAX:
				break
	return out

## The newest saved game this player is in, or "".
func newest_of(player: String) -> String:
	for id in _newest():
		if _games[id].owners.has(player):
			return id
	return ""

## The newest game this player lost their connection to within `seconds`
## (saved because everyone had gone), or "".
func dropped_by(player: String, seconds: float) -> String:
	var now := Time.get_unix_time_from_system()
	for id in _newest():
		var g: Dictionary = _games[id]
		if g.dropped.has(player) and now - float(g.at) <= seconds:
			return id
	return ""

## Its players' names by crew.
func names_of(id: String) -> Dictionary:
	return _games[id].names.duplicate() if _games.has(id) else {}

## The players who lost their connection to it (empty if nobody did).
func dropped_in(id: String) -> Array:
	return _games[id].dropped.duplicate() if _games.has(id) else []

## Saves the match now in GameConfig as game `id`: `game` is
## GameServer.save_state() (empty between games). `names` maps crew -> the
## name its player goes by; `dropped` lists the players who lost their
## connection.
func save(id: String, game: Dictionary, summary: String, names: Dictionary, dropped: Array) -> void:
	if folder == "" or not valid_id(id):
		return
	var path := path_of(id)
	GameConfig.save_game(game, summary, path)
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	var now := Time.get_unix_time_from_system()
	cfg.set_value("server", "at", now)
	cfg.set_value("server", "names", names)
	cfg.set_value("server", "dropped", dropped)
	cfg.save(path)
	_remember(id, cfg)
	prune()

## The players who were in it, by player id.
func owners_of(id: String) -> Array:
	return (_games[id].owners as Array).duplicate() if _games.has(id) else []

## `player` deletes saved game `id` from their list. If others played it too,
## it stays for them (the player's crew is no longer anyone's, so the
## computer would sail it); if nobody else has it, the file goes. Returns
## whether anyone still has it.
func forget(id: String, player: String) -> bool:
	if not owns(id, player):
		return false
	var cfg := ConfigFile.new()
	if cfg.load(path_of(id)) != OK:
		delete(id)
		return false
	var raw: Variant = cfg.get_value("save", "owners", {})
	var left := {}
	if raw is Dictionary:
		for t in raw:
			if str(raw[t]) != player:
				left[t] = raw[t]
	if left.is_empty():
		delete(id)
		return false
	cfg.set_value("save", "owners", left)
	var dropped: Variant = cfg.get_value("server", "dropped", [])
	if dropped is Array:
		cfg.set_value("server", "dropped", (dropped as Array).filter(func(p: Variant) -> bool: return str(p) != player))
	cfg.save(path_of(id))
	_remember(id, cfg)
	return true

func delete(id: String) -> void:
	if _games.has(id):
		_games.erase(id)
		var p := ProjectSettings.globalize_path(path_of(id))
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

## Drops what's too old, and what none of its players keeps any more.
func prune() -> void:
	var now := Time.get_unix_time_from_system()
	var kept := {}  # player -> how many of theirs are kept so far
	var keep := {}
	for id in _newest():
		var g: Dictionary = _games[id]
		if days > 0.0 and now - float(g.at) > days * 86400.0:
			continue
		var wanted: bool = g.owners.is_empty()
		for p in g.owners:
			if int(kept.get(p, 0)) < KEEP_EACH:
				wanted = true
		if wanted:
			keep[id] = true
			for p in g.owners:
				kept[p] = int(kept.get(p, 0)) + 1
	for id in _games.keys():
		if not keep.has(id):
			delete(id)

func _scan() -> void:
	_games.clear()
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	for f in dir.get_files():
		if not f.ends_with(".cfg"):
			continue
		var id := f.get_basename()
		if not valid_id(id):
			continue
		var cfg := ConfigFile.new()
		if cfg.load(folder.path_join(f)) == OK:
			_remember(id, cfg)

func _remember(id: String, cfg: ConfigFile) -> void:
	var owners: Array[String] = []
	var raw: Variant = cfg.get_value("save", "owners", {})
	if raw is Dictionary:
		for t in raw:
			var p := str(raw[t])
			if p != "" and not owners.has(p):
				owners.append(p)
	var names: Variant = cfg.get_value("server", "names", {})
	var at: Variant = cfg.get_value("server", "at", null)
	if at == null: # from before 0.10 (the old single campaign): when its file was written
		at = FileAccess.get_modified_time(ProjectSettings.globalize_path(path_of(id)))
	var dropped: Variant = cfg.get_value("server", "dropped", [])
	_games[id] = {
		"owners": owners,
		"keys": owners.map(func(p: String) -> String: return ServerFinder.back_key(p)),
		"names": names if names is Dictionary else {},
		"summary": _line(str(cfg.get_value("save", "summary", "")), names if names is Dictionary else {}),
		"at": float(at),
		"dropped": (dropped as Array).map(func(p: Variant) -> String: return str(p)) if dropped is Array else [],
	}

## "Turn 4 of game 2, with Ann and Ben": what the list shows.
static func _line(summary: String, names: Dictionary) -> String:
	var who: Array[String] = []
	for t in names:
		var n := str(names[t])
		if n != "" and not who.has(n):
			who.append(n)
	var text := summary.trim_prefix("Online match: ")
	if not who.is_empty():
		text += ", with " + (" and ".join(who) if who.size() <= 2 else ", ".join(who.slice(0, who.size() - 1)) + " and " + who[-1])
	return text.left(SUMMARY_MAX)

func _newest() -> Array:
	var ids := _games.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return float(_games[a].at) > float(_games[b].at))
	return ids
