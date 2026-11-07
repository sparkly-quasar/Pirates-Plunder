extends SceneTree

## For tools/forget_test.sh. Two jobs, by the first argument after --:
##   make <folder>          writes a saved game shared by ann-id and ben-id
##                          into a server's saves folder, and prints its id
##   forget <port> <id>     connects as this player (--player-id=) asking to
##                          delete that saved game, and prints what the
##                          server says (FORGET_SAID: ...)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var job := args[0]
	if job == "make":
		var Saves: Script = load("res://scripts/server_saves.gd")
		var saves: RefCounted = Saves.new()
		saves.open(args[1], 30.0)
		var gc: Node = root.get_node("GameConfig")
		# As a server saves a match between games: two crews, both players'.
		gc.reset()
		gc.mode = gc.Mode.SERVER
		gc.team_count = 2
		gc.team_target = 3
		for t in 2:
			gc.team_counts[t] = gc.balanced_counts(3)
		gc.seat_owners = {0: "ann-id", 1: "ben-id"}
		var id: String = Saves.new_id()
		saves.save(id, {}, "Turn 2 of game 1", {0: "Ann", 1: "Ben"}, [])
		print("MADE: ", id)
		quit()
		return
	var net: Node = root.get_node("Net")
	var gconf: Node = root.get_node("GameConfig")
	gconf.reset()
	gconf.mode = gconf.Mode.GUEST
	var said := {"text": ""}
	net.join_failed.connect(func(reason: String) -> void: said.text = reason)
	net.joined.connect(func() -> void: said.text = "(joined a game!)")
	if net.join_game("127.0.0.1:" + args[1]) != OK:
		print("FORGET_SAID: (couldn't connect)")
		quit(1)
		return
	net.server_request = {"forget": args[2]} # after connecting, as the server list does
	var waited := 0.0
	while said.text == "" and waited < 20.0:
		await process_frame
		waited += 1.0 / 60.0
	print("FORGET_SAID: ", said.text)
	net.leave()
	quit()
