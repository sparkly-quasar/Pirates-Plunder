extends RefCounted

## A dedicated server's Hall of Fame: every player who has finished a game
## there, by the player id their copy keeps (GameConfig.player_id()), with
## their lifetime totals on this server: games finished, games won, Battle
## Royale titles, chests got aboard and captures. Bragging rights only.
##
## One file, hall_of_fame.cfg, in the saves folder (so a Docker server keeps
## it in its volume), or in user:// when the server keeps no saves. Players
## show under their latest name. The server list asks for it with a Hall of
## Fame query (ServerFinder.board_query_packet()) and shows the top of it,
## the asker's own row marked, by a fingerprint of their id (back_key()).
##
## Not a class_name, like the server's own scripts. Load it by path.

const FILE := "hall_of_fame.cfg"
const KEYS := ["games", "wins", "titles", "aboard", "captures"]
const SHOW := 7 ## rows in a server list's Hall of Fame (they must fit one small packet)

var path := ""
var players := {} ## player id -> {name, games, wins, titles, aboard, captures, at}

func open(folder: String) -> void:
	path = (folder if folder != "" else "user://").path_join(FILE)
	players = {}
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	for pid in cfg.get_sections():
		var row := {"name": GameConfig.clean_name(str(cfg.get_value(pid, "name", ""))), "at": int(cfg.get_value(pid, "at", 0))}
		for k in KEYS:
			row[k] = maxi(0, int(cfg.get_value(pid, k, 0)))
		players[pid] = row

func save() -> void:
	if path == "":
		return
	var cfg := ConfigFile.new()
	for pid in players:
		for k in players[pid]:
			cfg.set_value(pid, k, players[pid][k])
	cfg.save(path)

## What one finished game adds, per player in it: [{pid, name, won, aboard,
## captures, title}]. `seats` maps each crew a player sailed to the end to
## [player id, name]; `titles` lists the crews that took a Battle Royale that
## just ended (empty otherwise). A game nobody won (the host left) counts for
## nothing.
static func results_of(gs: GameServer, seats: Dictionary, titles: Array = []) -> Array:
	var out := []
	if gs == null or not gs.won or gs.winner == GameServer.NOBODY:
		return out
	for t in seats:
		var who: Array = seats[t]
		if who.size() < 2 or str(who[0]) == "":
			continue
		var caught := 0
		for c in gs.characters:
			if c.team == int(t):
				caught += int(gs.tally[c.id].get("captures", 0))
		out.append({"pid": str(who[0]), "name": str(who[1]), "won": gs.is_winner(int(t)),
			"aboard": int(gs.delivered[int(t)]) if int(t) < gs.delivered.size() else 0,
			"captures": caught, "title": titles.has(int(t))})
	return out

## Adds a finished game's results and saves.
func record(results: Array) -> void:
	if results.is_empty():
		return
	for r in results:
		var pid := str(r.pid)
		var row: Dictionary = players.get(pid, {"name": "", "games": 0, "wins": 0, "titles": 0, "aboard": 0, "captures": 0, "at": 0})
		if str(r.get("name", "")) != "":
			row.name = GameConfig.clean_name(str(r.name))
		row.games = int(row.games) + 1
		row.wins = int(row.wins) + (1 if bool(r.get("won", false)) else 0)
		row.titles = int(row.titles) + (1 if bool(r.get("title", false)) else 0)
		row.aboard = int(row.aboard) + int(r.get("aboard", 0))
		row.captures = int(row.captures) + int(r.get("captures", 0))
		row.at = int(Time.get_unix_time_from_system())
		players[pid] = row
	save()

## Everyone, best first: wins, then Battle Royale titles, chests aboard,
## captures, and fewest games for the same.
func ranked() -> Array:
	var out := []
	for pid in players:
		var row: Dictionary = players[pid].duplicate()
		row["pid"] = pid
		out.append(row)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		for k in ["wins", "titles", "aboard", "captures"]:
			if int(a[k]) != int(b[k]):
				return int(a[k]) > int(b[k])
		if int(a.games) != int(b.games):
			return int(a.games) < int(b.games)
		return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return out

## What the server list is told: the top SHOW, each [rank, name, key, games,
## wins, titles, aboard, captures], and the asker's own row if they're
## further down (`asker` is their fingerprint, ServerFinder.back_key()).
func board_info(asker := "") -> Dictionary:
	var rows := []
	var mine := []
	var all := ranked()
	for i in all.size():
		var r: Dictionary = all[i]
		var key := ServerFinder.back_key(str(r.pid))
		var row := [i + 1, str(r.name).left(16), key, int(r.games), int(r.wins), int(r.titles), int(r.aboard), int(r.captures)]
		if i < SHOW:
			rows.append(row)
		elif asker != "" and key == asker:
			mine = row
	return {"rows": rows, "me": mine, "players": all.size()}
