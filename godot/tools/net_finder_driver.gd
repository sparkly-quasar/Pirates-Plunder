extends Node
# Drives the Play on a Server list against the real server (tools/
# finder_test.sh starts two: one as usual, one whose UDP status port is held
# by a socket that never answers, as Docker Desktop's broken forwarding left
# isaac's). Not shipped.
#
#   finder-udp   the usual server: found over UDP, and never asked over TCP.
#   finder-tcp   the server silent over UDP: found anyway, over TCP; its row
#                says so; its Hall of Fame comes back over TCP; and joining
#                reaches it (the game itself is over UDP, which still works).

const UDP_SERVER := "127.0.0.1:24702"
const TCP_SERVER := "127.0.0.1:24704"

var role := "finder-udp"
var failures := 0
var browser: Control

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish())
	browser = load("res://scenes/ServerBrowser.tscn").instantiate()
	browser.set("scan_tailnet", false) # only the test servers, not this computer's real one
	get_tree().root.add_child(browser)
	await get_tree().process_frame
	browser.address_edit.text = UDP_SERVER if role == "finder-udp" else TCP_SERVER
	browser.call("_look_up")
	var finder: ServerFinder = browser.finder
	var waited := 0.0
	while finder.servers().is_empty() and waited < 12.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	var found := finder.servers()
	_check(found.size() == 1, "%s: the server list finds the server (%.1f s)" % [role, waited])
	if found.is_empty():
		_finish()
		return
	var s: Dictionary = found[0]
	if role == "finder-udp":
		_check(str(s.get("via")) == "udp", "finder-udp: over UDP")
		await get_tree().create_timer(ServerFinder.TCP_AFTER + 3.0).timeout
		_check(str(finder.servers()[0].get("via")) == "udp" and finder.get("_tcp").is_empty(),
			"finder-udp: and it's never asked over TCP while UDP answers")
	else:
		_check(str(s.get("via")) == "tcp", "finder-tcp: over TCP, since UDP is silent")
		_check(waited < ServerFinder.TCP_AFTER + 4.0, "finder-tcp: within a few seconds (%.1f s)" % waited)
		await get_tree().create_timer(1.5).timeout # the list redraws
		var row_text := ""
		for l in browser.find_children("*", "Label", true, false):
			row_text += (l as Label).text + "\n"
		_check(row_text.contains("answering over TCP only"), "finder-tcp: its row says it's answering over TCP only")
		await get_tree().create_timer(ServerFinder.ASK_EVERY + 1.0).timeout
		_check(not finder.servers().is_empty() and str(finder.servers()[0].get("via")) == "tcp",
			"finder-tcp: and stays in the list (asked again over TCP)")
		var boards := []
		finder.board_found.connect(func(_srv: Dictionary, b: Dictionary) -> void: boards.append(b))
		finder.ask_board(finder.servers()[0])
		waited = 0.0
		while boards.is_empty() and waited < 5.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		_check(not boards.is_empty(), "finder-tcp: its Hall of Fame comes back over TCP")
		# Nobody has started a game there, so the server answers a joiner by
		# saying so: that answer can only come over the game's UDP connection.
		var told := [""]
		Net.join_failed.connect(func(why: String) -> void: told[0] = why)
		_check(Net.join_game(str(finder.servers()[0].address)) == OK, "finder-tcp: joining its address (%s) starts" % finder.servers()[0].address)
		waited = 0.0
		while told[0] == "" and waited < 10.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		_check(told[0].contains("Nobody has started a game"), "finder-tcp: and the server answers over the game's UDP connection: %s" % told[0])
	_finish()

func _check(ok: bool, what: String) -> void:
	print("  [%s] %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _finish() -> void:
	print("NET_RESULT %s %s" % [role, "PASS" if failures == 0 else "FAIL"])
	Net.leave()
	get_tree().quit(0 if failures == 0 else 1)
