extends SceneTree

## For tools/seat_test.sh: a player on the real server, by the first argument
## after -- (and --player-id= for who they are):
##   continue <port> <id>  continues saved game <id>, asks to set sail at once
##                         (it shouldn't: someone is missing), then waits for
##                         the game to set sail once they're back
##   join <port>           joins whatever is open, and says what happened

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var net: Node = root.get_node("Net")
	var gconf: Node = root.get_node("GameConfig")
	gconf.reset()
	gconf.mode = gconf.Mode.GUEST
	var said := {"refused": "", "joined": false}
	net.join_failed.connect(func(reason: String) -> void: said.refused = reason)
	net.joined.connect(func() -> void: said.joined = true)
	if net.join_game("127.0.0.1:" + args[1]) != OK:
		print("SEAT: couldn't connect")
		quit(1)
		return
	net.server_request = {"continue": args[2]} if args[0] == "continue" else null
	if not await _until(func() -> bool: return said.joined or said.refused != "", 20.0):
		print("SEAT: no answer")
		quit(1)
		return
	if said.refused != "":
		print("SEAT: refused: ", said.refused)
		quit()
		return
	print("SEAT: in, as crew %d" % gconf.my_team)
	if args[0] == "continue":
		await _until(func() -> bool: return not net.lobby.is_empty(), 10.0)
		net.request_sail()
		await _until(func() -> bool: return net.match_started or net.game_server != null, 4.0)
		print("SEAT: asked to set sail alone; sailed: %s; waiting for: %s" % [net.game_server != null, ", ".join(net.lobby.get("waiting", []))])
		var sailed := await _until(func() -> bool: return net.game_server != null and is_instance_valid(net.game_server) and net.game_server.started, 60.0)
		print("SEAT: sailed once they were back: %s" % sailed)
	else:
		var sailed := await _until(func() -> bool: return net.game_server != null and is_instance_valid(net.game_server) and net.game_server.started, 40.0)
		print("SEAT: sailed: %s" % sailed)
	net.leave()
	await create_timer(0.5).timeout
	quit()

func _until(cond: Callable, limit: float) -> bool:
	var waited := 0.0
	while not cond.call():
		await process_frame
		waited += 1.0 / 60.0
		if waited > limit:
			return false
	return true
