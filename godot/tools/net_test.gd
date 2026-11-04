extends Node
# Two-process network test. Run one host and one guest on this machine:
#   godot --headless --path . res://tools/NetTest.tscn -- --role=host
#   godot --headless --path . res://tools/NetTest.tscn -- --role=guest
# They connect over localhost, land on the same island, fight a duel (the navs
# attack, the pirates defend from the other process), then hand the turn over
# and the pirates move. Each prints NET_RESULT and exits non-zero on failure.
# Four crews, three processes (see net_crews_driver.gd):
#   godot --headless --path . res://tools/NetTest.tscn -- --role=crews-host
#   godot --headless --path . res://tools/NetTest.tscn -- --role=crews-pirates
#   godot --headless --path . res://tools/NetTest.tscn -- --role=crews-corsairs
# Versions (see net_update_driver.gd): a guest posing as an older version
# downloads the host's "game" (test files); a guest acting like a copy from
# before 0.6.1 is let in on the old handshake:
#   godot --headless --path . res://tools/NetTest.tscn -- --role=update-host
#   godot --headless --path . res://tools/NetTest.tscn -- --role=update-guest --pretend-version=0.0.1
#   (then again: --role=update-host and --role=legacy-guest)
# The dedicated server (see net_server_driver.gd): the real server and four
# players in five processes; tools/server_test.sh starts them all:
#   godot --headless --path . -- --server --port=24697 --once --turn-seconds=10
#   godot --headless --path . res://tools/NetTest.tscn -- --role=server-navs
#   godot --headless --path . res://tools/NetTest.tscn -- --role=server-pirates
#   godot --headless --path . res://tools/NetTest.tscn -- --role=server-old --pretend-version=0.0.1
#   godot --headless --path . res://tools/NetTest.tscn -- --role=server-late
# A saved online match (see net_resume_driver.gd): a host and two friends,
# each with its own --player-id=, over three stages (play and save, continue
# between games, continue partway through a game); tools/resume_test.sh runs them:
#   godot --headless --path . res://tools/NetTest.tscn -- --role=resume-host --stage=play --player-id=host-1
#   godot --headless --path . res://tools/NetTest.tscn -- --role=resume-guest-a --stage=play --player-id=guest-a
#   godot --headless --path . res://tools/NetTest.tscn -- --role=resume-guest-b --stage=play --player-id=guest-b
# Games players start on a server (see net_lobby_driver.gd): the real server
# (lobby=players) and three players; tools/lobby_test.sh runs them:
#   godot --headless --path . -- --server --port=24693 --once --most-crews=4
#   godot --headless --path . res://tools/NetTest.tscn -- --role=lobby-a --player-name=Alice
#   godot --headless --path . res://tools/NetTest.tscn -- --role=lobby-b --player-name=Bob
#   godot --headless --path . res://tools/NetTest.tscn -- --role=lobby-c --player-name=Cara
# and, to see what this computer finds through Tailscale: --role=lobby-scan
# A browser and a desktop copy on one server (see net_web_driver.gd): the real
# server and two players, one over WebSockets; tools/web_test.sh runs them:
#   godot --headless --path . -- --server --port=24689 --once
#   godot --headless --path . res://tools/NetTest.tscn -- --role=web-wendy --player-name=Wendy
#   godot --headless --path . res://tools/NetTest.tscn -- --role=web-dan --player-name=Dan
# Getting back into your crew after the connection drops (see
# net_rejoin_driver.gd); tools/rejoin_test.sh runs them:
#   godot --headless --path . -- --server --port=24685 --once --rejoin-seconds=20
#   godot --headless --path . res://tools/NetTest.tscn -- --role=rejoin-ann --player-name=Ann
#   godot --headless --path . res://tools/NetTest.tscn -- --role=rejoin-ben --player-name=Ben
# Check for Updates on the server list (see net_check_update_driver.gd);
# tools/check_update_test.sh runs them, one after another:
#   godot --headless --path . -- --server --port=24677 --downloads=<folder>
#   godot --headless --path . res://tools/NetTest.tscn -- --role=check-old --pretend-version=0.0.1
#   godot --headless --path . res://tools/NetTest.tscn -- --role=check-same
#   godot --headless --path . res://tools/NetTest.tscn -- --role=check-newer --pretend-version=99.0.0
# The server list over UDP, and over TCP when UDP is silent (see
# net_finder_driver.gd); tools/finder_test.sh runs them:
#   godot --headless --path . res://tools/NetTest.tscn -- --role=finder-udp
#   godot --headless --path . res://tools/NetTest.tscn -- --role=finder-tcp
# Battle Royale (see net_royale_driver.gd); tools/royale_test.sh runs them:
#   godot --headless --path . -- --server --port=24697 --once
#   godot --headless --path . res://tools/NetTest.tscn -- --role=royale-ann --player-name=Ann
#   godot --headless --path . res://tools/NetTest.tscn -- --role=royale-bo --player-name=Bo
# The scene change into the real game frees this node, so the work is done by
# a driver parked on the root, which survives it. Not shipped.

func _ready() -> void:
	var role := "host"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.trim_prefix("--role=")
	var driver := Node.new()
	# --role=crews-host / crews-pirates / crews-corsairs: the four-crew test.
	var script := "res://tools/net_driver.gd"
	if role.begins_with("crews"):
		script = "res://tools/net_crews_driver.gd"
	elif role.begins_with("update") or role == "legacy-guest":
		script = "res://tools/net_update_driver.gd"
	elif role.begins_with("server"):
		script = "res://tools/net_server_driver.gd"
	elif role.begins_with("resume"):
		script = "res://tools/net_resume_driver.gd"
	elif role.begins_with("lobby"):
		script = "res://tools/net_lobby_driver.gd"
	elif role.begins_with("web"):
		script = "res://tools/net_web_driver.gd"
	elif role.begins_with("rejoin"):
		script = "res://tools/net_rejoin_driver.gd"
	elif role.begins_with("check"):
		script = "res://tools/net_check_update_driver.gd"
	elif role.begins_with("royale"):
		script = "res://tools/net_royale_driver.gd"
	elif role.begins_with("finder"):
		script = "res://tools/net_finder_driver.gd"
	driver.set_script(load(script))
	driver.set("role", role)
	get_tree().root.add_child.call_deferred(driver)
